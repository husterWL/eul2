//
//  main.swift
//  FanHelper
//
//  Created by Gao Sun on 2026/6/11.
//  Copyright © 2026 Gao Sun. All rights reserved.
//
//  Privileged fan helper daemon (design §4.6 / asks 15–16). Registered via
//  SMAppService from the app at the moment the user first enables fan
//  control — never at launch (P6). Launch-on-demand, root, no KeepAlive.
//
//  Safety invariants owned HERE, not by the UI:
//  - every target is clamped to the hardware's real F{id}Mn...F{id}Mx
//  - fans revert to Auto when: the last XPC connection drops, the dead-man
//    heartbeat goes silent, SIGTERM arrives, or the daemon starts (a crashed
//    predecessor may have left fans pinned)

import Foundation

final class FanController: NSObject, FanHelperProtocol, @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.gaosun.eul.helper.fans")
    private var smcOpened = false
    private var overriddenFans = Set<Int>()
    private var lastPing = Date()
    /// fan count and min/max RPM are static hardware facts — read them once
    /// instead of paying 3+ SMC round trips on every control write
    private var cachedFanCount: Int?
    private var fanLimits: [Int: (min: Int, max: Int)] = [:]

    var hasOverrides: Bool {
        queue.sync { !overriddenFans.isEmpty }
    }

    var secondsSinceLastPing: TimeInterval {
        queue.sync { Date().timeIntervalSince(lastPing) }
    }

    private func ensureSMC() throws {
        if !smcOpened {
            try SMCKit.open()
            smcOpened = true
        }
    }

    /// must be called on `queue`. Validates the client-supplied id against
    /// the real fan count and returns the hardware limits (cached).
    private func validatedLimits(id: Int) throws -> (min: Int, max: Int) {
        try ensureSMC()
        if cachedFanCount == nil {
            cachedFanCount = (try? SMCKit.fanCount()) ?? 0
        }
        let count = cachedFanCount ?? 0
        guard id >= 0, id < count else {
            throw SMCKit.SMCError.keyNotFound(code: "fan \(id)")
        }
        if let limits = fanLimits[id] {
            return limits
        }
        let limits = (
            min: (try? SMCKit.fanMinSpeed(id)) ?? 0,
            max: (try? SMCKit.fanMaxSpeed(id)) ?? 0
        )
        fanLimits[id] = limits
        return limits
    }

    func setFanForced(id: Int, targetRPM: Double, reply: @escaping (String?) -> Void) {
        queue.async { [self] in
            do {
                // validate + clamp in Double space — Int(Double) TRAPS on
                // NaN/infinity/out-of-range, and targetRPM crosses a trust
                // boundary; never trust the client
                guard targetRPM.isFinite else {
                    reply("invalid target RPM")
                    return
                }
                let limits = try validatedLimits(id: id)
                guard limits.max > 0 else {
                    reply("fan \(id) reports no max speed")
                    return
                }
                let clamped = Int(min(max(targetRPM, Double(max(limits.min, 1))), Double(limits.max)))
                // track BEFORE writing: a partial write (mode set, target
                // failed) must stay covered by the revert machinery
                overriddenFans.insert(id)
                try SMCKit.fanSetForced(id, targetSpeed: clamped)
                lastPing = Date()
                reply(nil)
            } catch {
                reply(String(describing: error))
            }
        }
    }

    func setFanAuto(id: Int, reply: @escaping (String?) -> Void) {
        queue.async { [self] in
            do {
                // same trust boundary as setFanForced: an out-of-range id
                // used to reach FourCharCode(fromString:) and crash the
                // root daemon via its 4-character precondition
                _ = try validatedLimits(id: id)
                try SMCKit.fanSetAuto(id)
                overriddenFans.remove(id)
                reply(nil)
            } catch {
                reply(String(describing: error))
            }
        }
    }

    func revertAllToAuto(reply: @escaping (String?) -> Void) {
        queue.async { [self] in
            reply(revertAllLocked())
        }
    }

    /// must be called on `queue`
    private func revertAllLocked() -> String? {
        do {
            try ensureSMC()
            let count = (try? SMCKit.fanCount()) ?? 0
            for id in 0..<count {
                try? SMCKit.fanSetAuto(id)
            }
            overriddenFans.removeAll()
            return count > 0 ? nil : "no fans"
        } catch {
            return String(describing: error)
        }
    }

    func revertAllSync() {
        queue.sync {
            _ = revertAllLocked()
        }
    }

    func ping(reply: @escaping (String, [Int]) -> Void) {
        queue.async { [self] in
            lastPing = Date()
            reply(FanHelperConstants.version, Array(overriddenFans).sorted())
        }
    }
}

final class ListenerDelegate: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    let controller: FanController
    private var activeConnections = 0
    private let connectionQueue = DispatchQueue(label: "com.gaosun.eul.helper.connections")

    init(controller: FanController) {
        self.controller = controller
    }

    /// The helper and the app are built and signed together, so the client
    /// requirement pins to the helper's OWN team — whichever real signing
    /// team produced this binary — with the upstream team as fallback. This
    /// keeps the requirement correct for forks/dev teams without edits.
    static let teamIdentifier: String = {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code = code else {
            return "M8G2RFZVFV"
        }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode = staticCode else {
            return "M8G2RFZVFV"
        }
        var info: CFDictionary?
        guard
            SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
            let dictionary = info as? [String: Any],
            let team = dictionary[kSecCodeInfoTeamIdentifier as String] as? String,
            !team.isEmpty
        else {
            return "M8G2RFZVFV"
        }
        return team
    }()

    func listener(_: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // only eul may talk to this daemon: kernel-verified signing
        // requirement (Stats shipped a root LPE by skipping this —
        // GHSA-qwhf-px96-7f6v). Matches Apple Development and Developer ID
        // leaf certificates for the team.
        if #available(macOS 13.0, *) {
            connection.setCodeSigningRequirement(
                "anchor apple generic and identifier \"com.gaosun.eul\" and certificate leaf[subject.OU] = \"\(Self.teamIdentifier)\""
            )
        } else {
            // the daemon is only ever registered via SMAppService (13+)
            return false
        }

        connection.exportedInterface = NSXPCInterface(with: FanHelperProtocol.self)
        connection.exportedObject = controller
        connectionQueue.sync { activeConnections += 1 }
        connection.invalidationHandler = { [weak self] in
            guard let self = self else {
                return
            }
            let remaining: Int = self.connectionQueue.sync {
                self.activeConnections -= 1
                return self.activeConnections
            }
            // the app went away — its fans must not stay pinned
            if remaining <= 0, self.controller.hasOverrides {
                self.controller.revertAllSync()
            }
        }
        connection.resume()
        return true
    }
}

/// a crashed predecessor may have left fans forced — start from a safe state
let controller = FanController()
controller.revertAllSync()

let delegate = ListenerDelegate(controller: controller)
let listener = NSXPCListener(machServiceName: FanHelperConstants.machServiceName)
listener.delegate = delegate
listener.resume()

/// dead-man watchdog: overrides with no heartbeat for 45 s mean the app died
/// without cleanup (force-quit, crash before invalidation) — revert.
/// NOTE: the deadline is wall-clock on purpose — after sleep/wake the gap
/// always exceeds 45 s, so fans return to Auto on wake. That is the safe
/// direction (the app re-asserts its override on the next user interaction).
let watchdog = DispatchSource.makeTimerSource()
watchdog.schedule(deadline: .now() + 15, repeating: 15)
watchdog.setEventHandler {
    if controller.hasOverrides, controller.secondsSinceLastPing > 45 {
        controller.revertAllSync()
    }
}

watchdog.resume()

signal(SIGTERM, SIG_IGN)
let sigterm = DispatchSource.makeSignalSource(signal: SIGTERM)
sigterm.setEventHandler {
    controller.revertAllSync()
    exit(0)
}

sigterm.resume()

RunLoop.main.run()
