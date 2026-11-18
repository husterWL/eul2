//
//  Container.swift
//  eul
//
//  Created by Gao Sun on 2020/11/5.
//  Copyright © 2020 Gao Sun. All rights reserved.
//

import Foundation
import Security

public enum Container {
    /// macOS 15 protects app-group containers and verifies ownership by the
    /// team-ID prefix; an unprefixed group ID reads as ANOTHER app's data and
    /// every access prompts "eul would like to access data from other apps".
    /// The entitlements declare $(TeamIdentifierPrefix)com.gaosun.eul.shared,
    /// so ask our own signature which group we were actually granted — code
    /// and entitlement can never disagree, and forks under any team work
    /// unchanged. Unsigned dev builds fall back to the legacy suite.
    public static let appGroupID: String = {
        guard
            let task = SecTaskCreateFromSelf(nil),
            let value = SecTaskCopyValueForEntitlement(task, "com.apple.security.application-groups" as CFString, nil),
            let group = (value as? [String])?.first
        else {
            return "com.gaosun.eul.shared"
        }
        return group
    }()

    /// UserDefaults is thread-safe by contract; `nonisolated(unsafe)` tells
    /// Swift 6 what the framework already guarantees.
    public nonisolated(unsafe) static let defaults = UserDefaults(suiteName: appGroupID)

    public static func get<T: SharedEntry>(_ type: T.Type) -> T? {
        // fresh coder per call: PropertyListEncoder/Decoder are NOT
        // thread-safe and a shared static would be exactly the kind of
        // cross-queue state Swift 6 rejects
        if let data = defaults?.data(forKey: T.containerKey), let decoded = try? PropertyListDecoder().decode(type, from: data) {
            return decoded
        }
        return nil
    }

    public static func set<T: SharedEntry>(_ value: T?) {
        if let value = value, let encoded = try? PropertyListEncoder().encode(value) {
            defaults?.setValue(encoded, forKey: T.containerKey)
        }
    }
}
