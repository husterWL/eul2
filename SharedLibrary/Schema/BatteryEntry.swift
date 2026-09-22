//
//  BatteryEntry.swift
//  SharedLibrary
//
//  Created by Gao Sun on 2020/11/7.
//  Copyright © 2020 Gao Sun. All rights reserved.
//

import Foundation

@available(macOSApplicationExtension 11, *)
public struct BatteryEntry: SharedWidgetEntry {
    public init(date: Date = Date(), outdated: Bool = false, isCharging: Bool = false, acPowered: Bool = false, charge: Double? = nil, capacity: Int = 0, maxCapacity: Int? = nil, designCapacity: Int? = nil, cycleCount: Int = 0, condition: BatteryEntry.BatteryCondition = BatteryCondition.good) {
        self.date = date
        self.outdated = outdated
        self.isCharging = isCharging
        self.acPowered = acPowered
        self.charge = charge
        self.capacity = capacity
        self.maxCapacity = maxCapacity
        self.designCapacity = designCapacity
        self.cycleCount = cycleCount
        self.condition = condition
    }

    public enum BatteryCondition: String, Codable {
        case good
        case fair
        case poor
    }

    public enum PowerSourceState: String, Codable {
        case battery
        case acPower
        case unknown
    }

    public init(date: Date, outdated: Bool) {
        self.date = date
        self.outdated = outdated
    }

    public static let containerKey = "BatteryEntry"
    public static let kind = "BatteryWidget"
    public static let sample = BatteryEntry(charge: 1, capacity: 100, maxCapacity: 100, designCapacity: 100)

    public var date = Date()
    public var outdated = false
    public var isCharging = false
    public var acPowered = false
    public var charge: Double?
    public var capacity = 0
    public var maxCapacity: Int?
    public var designCapacity: Int?
    public var cycleCount = 0
    public var condition = BatteryCondition.good

    public var chargeString: String {
        guard isValid, let charge = charge else {
            return "N/A"
        }
        return charge.percentageString
    }

    /// Full-charge capacity relative to design capacity, capped at 100% — a
    /// fresh pack reads slightly above its design value. NaN when the hardware
    /// values are unavailable, so `percentageString` renders "N/A" instead of
    /// inventing a reading from a zero divisor.
    public var health: Double {
        guard let maxCapacity = maxCapacity, let designCapacity = designCapacity, designCapacity > 0 else {
            return .nan
        }
        return min(Double(maxCapacity) / Double(designCapacity), 1)
    }
}
