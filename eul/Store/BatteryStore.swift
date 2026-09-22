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

class BatteryStore: ObservableObject, Refreshable {
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

    @objc func refresh() {
        io = Info.Battery()
        let hardware = IOHelper.batteryHardware()

        // A Mac without a battery has neither a power source nor hardware
        // capacity, so the battery UI stays hidden rather than reporting zeros.
        isValid = io.isPresent || hardware.hasCapacity

        acPowered = io.powerSource == .acPower
        charging = io.isCharging
        capacity = hardware.currentCapacity
        maxCapacity = hardware.maxCapacity
        designCapacity = hardware.designCapacity
        cycleCount = hardware.cycleCount ?? 0
        timeRemaining = io.powerSource == .battery ? io.timeRemainingFormatted : "∞"
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
