//
//  DisplayBrightness.swift
//  eul
//
//  Created for Clean Mode (hardware wipe).
//

import CoreGraphics
import Darwin
import Foundation

/// Built-in display dimming for Clean Mode. Drives the internal panel's
/// backlight through the private DisplayServices framework — the one API that
/// works on both Intel and Apple Silicon laptops — resolved with `dlsym` so
/// nothing links against private headers (the same approach as
/// `AppleSiliconSensors`). If the symbols ever vanish on a future macOS,
/// dimming is simply skipped: the opaque black overlay is the guarantee,
/// brightness-to-zero is the nicety.
/// Main-actor confined by design: only Clean Mode drives it, on the main
/// thread (Swift 6 makes that contract explicit).
@MainActor
final class DisplayBrightness {
    private typealias GetFunc = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFunc = @convention(c) (CGDirectDisplayID, Float) -> Int32

    private let getBrightness: GetFunc?
    private let setBrightness: SetFunc?

    /// brightness snapshotted at dim time, per display, so exit restores exactly
    private var saved: [CGDirectDisplayID: Float] = [:]
    /// last fraction written, so a ramp resumes from where the screen actually is
    private var currentFraction: Double = 1
    private var rampTimer: Timer?
    /// ramp progress lives on the instance, not in a captured local `var` —
    /// a @Sendable Timer closure must not mutate captured locals (Swift 6)
    private var rampStep = 0
    private var rampSteps = 1
    private var rampStart: Double = 1
    private var rampTarget: Double = 1
    private var rampCompletion: (@Sendable () -> Void)?

    init() {
        guard let handle = dlopen(
            "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices",
            RTLD_NOW
        ) else {
            getBrightness = nil
            setBrightness = nil
            return
        }
        getBrightness = dlsym(handle, "DisplayServicesGetBrightness").map { unsafeBitCast($0, to: GetFunc.self) }
        setBrightness = dlsym(handle, "DisplayServicesSetBrightness").map { unsafeBitCast($0, to: SetFunc.self) }
    }

    var isAvailable: Bool {
        getBrightness != nil && setBrightness != nil
    }

    private func activeDisplays() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else {
            return []
        }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else {
            return []
        }
        return Array(ids.prefix(Int(count)))
    }

    /// Snapshot current brightness for every readable display. Call before dimming.
    func capture() {
        rampTimer?.invalidate()
        rampTimer = nil
        saved = [:]
        currentFraction = 1
        guard let getBrightness = getBrightness else {
            return
        }
        for id in activeDisplays() {
            var value: Float = 0
            if getBrightness(id, &value) == 0, value >= 0 {
                saved[id] = value
            }
        }
    }

    /// Set every captured display to `fraction` (0...1) of its saved brightness.
    func setFraction(_ fraction: Double) {
        guard let setBrightness = setBrightness else {
            return
        }
        let clamped = Float(max(0, min(1, fraction)))
        for (id, value) in saved {
            _ = setBrightness(id, value * clamped)
        }
        currentFraction = Double(clamped)
    }

    /// Smoothly move to `fraction` over `duration` — used for the dim-to-dark
    /// transition and the release-from-hold fade. (The hold itself writes
    /// `setFraction` directly so the screen tracks the ring.)
    func ramp(toFraction target: Double, duration: TimeInterval, completion: (@Sendable () -> Void)? = nil) {
        rampTimer?.invalidate()
        rampTimer = nil
        guard isAvailable, !saved.isEmpty, duration > 0 else {
            setFraction(target)
            completion?()
            return
        }
        rampStart = currentFraction
        rampTarget = target
        rampCompletion = completion
        rampSteps = max(1, Int(duration * 30))
        rampStep = 0
        // .common modes: a ramp scheduled in .default would stall during
        // gesture/menu tracking — and this drives the Clean Mode exit fade.
        // The closure ignores its `timer` parameter (non-Sendable, can't
        // cross into the MainActor region) and invalidates via self.rampTimer.
        let timer = Timer(timeInterval: duration / Double(rampSteps), repeats: true) { [weak self] _ in
            // main-runloop timer: bridge into the MainActor class
            MainActor.assumeIsolated {
                guard let self = self else {
                    return
                }
                self.rampStep += 1
                let progress = Double(self.rampStep) / Double(self.rampSteps)
                self.setFraction(self.rampStart + (self.rampTarget - self.rampStart) * progress)
                if self.rampStep >= self.rampSteps {
                    self.rampTimer?.invalidate()
                    self.rampTimer = nil
                    let completion = self.rampCompletion
                    self.rampCompletion = nil
                    completion?()
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        rampTimer = timer
    }

    /// Cancel an in-flight ramp so a caller can take direct control of the
    /// backlight (the hold-to-exit feedback writes `setFraction` itself).
    func stopRamp() {
        rampTimer?.invalidate()
        rampTimer = nil
    }

    /// Restore the snapshot exactly and forget it. Idempotent.
    func restore() {
        rampTimer?.invalidate()
        rampTimer = nil
        if let setBrightness = setBrightness {
            for (id, value) in saved {
                _ = setBrightness(id, value)
            }
        }
        saved = [:]
        currentFraction = 1
    }
}
