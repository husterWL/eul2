//
//  KeyboardLock.swift
//  eul
//
//  Created for Clean Mode (hardware wipe).
//

import Cocoa
import CoreGraphics

/// Swallows all keyboard input via a session-level CGEventTap for the duration
/// of Clean Mode, so the keys can be wiped without typing into anything. The
/// tap belongs to this process — macOS tears it down automatically if eul dies,
/// so a crash or force-quit can never leave the keyboard stuck off. Re-enabling
/// never depends on a keypress: the overlay's mouse hold-to-exit and the
/// auto-timeout are the only ways out, and both call `unlock()`.
///
/// Only keyboard event types are tapped — never mouse — so the trackpad stays
/// live to drive the way out. Media keys (brightness / keyboard backlight /
/// volume) ride a separate system path; if one slips through it is harmless:
/// the opaque overlay hides the change and exit restores the captured
/// brightness regardless.
final class KeyboardLock {
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    deinit {
        unlock()
    }

    /// Keyboard permissions (TCC) — preflight without prompting. The tap is
    /// an ACTIVE filter (.defaultTap, it drops events), which needs
    /// Accessibility; Input Monitoring alone only covers listen-only taps.
    /// Check both so the user is never sent in circles granting a permission
    /// that cannot unlock the tap.
    static func hasPermission() -> Bool {
        CGPreflightListenEventAccess() && AXIsProcessTrusted()
    }

    /// Triggers the system prompts the first time; a no-op once the user
    /// decided. Requests both permissions the active tap depends on.
    @discardableResult
    static func requestPermission() -> Bool {
        let listen = CGRequestListenEventAccess()
        // the literal key string behind kAXTrustedCheckOptionPrompt — the
        // global `var` symbol itself is not concurrency-safe to reference
        // under Swift 6
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        let accessibility = AXIsProcessTrustedWithOptions(options)
        return listen && accessibility
    }

    /// Opens System Settings at the pane for whichever permission is still
    /// missing (Accessibility first — it is the one the active tap needs).
    static func openSettings() {
        let pane = AXIsProcessTrusted() ? "Privacy_ListenEvent" : "Privacy_Accessibility"
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    var isLocked: Bool {
        tap != nil
    }

    /// Returns `false` when the tap can't be created — in practice the cause
    /// is a missing keyboard permission (Input Monitoring / Accessibility).
    @discardableResult
    func lock() -> Bool {
        guard tap == nil else {
            return true
        }
        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue)
                | (1 << CGEventType.keyUp.rawValue)
                | (1 << CGEventType.flagsChanged.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            // The system disables a tap it judges slow; ours is trivial, but
            // re-enable defensively so the keyboard can never silently return
            // mid-clean.
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let userInfo = userInfo {
                    Unmanaged<KeyboardLock>.fromOpaque(userInfo).takeUnretainedValue().reEnable()
                }
                return Unmanaged.passUnretained(event)
            }
            // swallow every key — returning nil drops the event
            return nil
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        runLoopSource = source
        return true
    }

    private func reEnable() {
        guard let tap = tap else {
            return
        }
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    /// Idempotent — safe to call from every exit edge (hold, timeout, terminate).
    func unlock() {
        if let tap = tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let runLoopSource = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        // explicit invalidation — don't rely on ARC's implicit teardown timing
        // for the tap's mach port
        if let tap = tap {
            CFMachPortInvalidate(tap)
        }
        runLoopSource = nil
        tap = nil
    }
}
