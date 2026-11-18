//
//  BatteryStore.swift
//  eul
//
//  Created by Gao Sun on 2020/8/7.
//  Copyright © 2020 Gao Sun. All rights reserved.
//

import Foundation
import SharedLibrary
import WidgetKit

class BatteryStore: ObservableObject, Refreshable, @unchecked Sendable {
    var io = Info.Battery()

    @Published var isValid = false

    @Published var acPowered = false
    @Published var charging = false
    @Published var capacity: Int?
    @Published var maxCapacity: Int?
    @Published var designCapacity: Int?
    @Published var cycleCount = 0
    @Published var timeRemaining = "∞"

    var charge: Double {
        io.currentCharge
    }

    /// The one display-only health cue: charge is monotonic on battery power,
    /// so a plain threshold can't flap like a raw usage sample would. Plugged
    /// in, a low percentage is a non-event — no color. Single source of truth
    /// for BOTH the panel tile and the bar slot (§5.2: health colors only).
    var severity: HealthLevel {
        guard !acPowered else {
            return .normal
        }
        if charge <= 0.1 {
            return .critical
        }
        if charge <= 0.2 {
            return .elevated
        }
        return .normal
    }

    /// Full-charge capacity over design capacity, capped at 100%: a fresh pack
    /// legitimately reads slightly above its design value and Apple reports that
    /// as 100%. `nil` — never a fabricated number — when the hardware values are
    /// unavailable.
    var health: Double? {
        guard let maxCapacity = maxCapacity, let designCapacity = designCapacity, designCapacity > 0 else {
            return nil
        }
        return min(Double(maxCapacity) / Double(designCapacity), 1)
    }

    var healthString: String {
        health?.percentageString ?? "N/A"
    }

    var maxCapacityText: String {
        capacityText(maxCapacity)
    }

    var designCapacityText: String {
        capacityText(designCapacity)
    }

    /// Unknown stays visibly unknown instead of printing a believable-looking
    /// "0 mAh".
    private func capacityText(_ value: Int?) -> String {
        guard let value = value else {
            return "—"
        }
        return "\(value) mAh"
    }

    /// The AppleSmartBattery registry dump (pack/bank/cell entries, each with
    /// the full nested BatteryData/LifetimeData payload) is one of the heaviest
    /// IOKit reads in the refresh chain — and designCapacity/cycleCount barely
    /// change. Cache it; the IOPS charge/charging state stays per-tick.
    private static let hardwareCacheInterval: TimeInterval = 60
    private var hardwareCache: IOHelper.BatteryHardware?
    private var hardwareCacheAt = Date.distantPast

    private func batteryHardwareCached() -> IOHelper.BatteryHardware {
        if let cached = hardwareCache, Date().timeIntervalSince(hardwareCacheAt) < Self.hardwareCacheInterval {
            return cached
        }
        let hardware = IOHelper.batteryHardware()
        hardwareCache = hardware
        hardwareCacheAt = Date()
        return hardware
    }

    @objc func refresh() {
        io = Info.Battery()
        let hardware = batteryHardwareCached()

        // A Mac without a battery has neither a power source nor hardware
        // capacity, so the battery UI stays hidden rather than reporting zeros.
        //
        // Assignments are change-guarded: @Published fires objectWillChange on
        // EVERY set, and these values move on a minutes cadence — unguarded
        // writes invalidated every observing view on every 3 s tick.
        let newIsValid = io.isPresent || hardware.hasCapacity
        if isValid != newIsValid {
            isValid = newIsValid
        }
        let newAcPowered = io.powerSource == .acPower
        if acPowered != newAcPowered {
            acPowered = newAcPowered
        }
        if charging != io.isCharging {
            charging = io.isCharging
        }
        if capacity != hardware.currentCapacity {
            capacity = hardware.currentCapacity
        }
        if maxCapacity != hardware.maxCapacity {
            maxCapacity = hardware.maxCapacity
        }
        if designCapacity != hardware.designCapacity {
            designCapacity = hardware.designCapacity
        }
        let newCycleCount = hardware.cycleCount ?? 0
        if cycleCount != newCycleCount {
            cycleCount = newCycleCount
        }
        let newTimeRemaining = io.powerSource == .battery ? io.timeRemainingFormatted : "∞"
        if timeRemaining != newTimeRemaining {
            timeRemaining = newTimeRemaining
        }
        writeToContainer()
    }

    func writeToContainer() {
        guard WidgetReloader.shouldWrite(kind: BatteryEntry.kind) else {
            return
        }
        Container.set(BatteryEntry(
            isCharging: charging, acPowered: acPowered, charge: charge, capacity: capacity ?? 0, maxCapacity: maxCapacity, designCapacity: designCapacity, cycleCount: cycleCount, condition: io.condition
        ))
        WidgetReloader.requestReload(ofKind: BatteryEntry.kind)
    }

    init() {
        initObserver(for: .StoreShouldRefresh)
        refresh()
    }
}
