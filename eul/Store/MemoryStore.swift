//
//  MemoryStore.swift
//  eul
//
//  Created by Gao Sun on 2020/6/29.
//  Copyright © 2020 Gao Sun. All rights reserved.
//

import Foundation
import SharedLibrary
import SystemKit
import WidgetKit

class MemoryStore: ObservableObject, Refreshable, @unchecked Sendable {
    @Published var free: Double = 0
    @Published var active: Double = 0
    @Published var inactive: Double = 0
    @Published var wired: Double = 0
    @Published var compressed: Double = 0
    @Published var appMemory: Double = 0
    @Published var cachedFiles: Double = 0
    @Published var temp: Double?
    @Published var swapUsed: Double = 0
    @Published var swapTotal: Double = 0

    var used: Double {
        appMemory + wired + compressed
    }

    var usedPercentage: Double {
        guard total > 0 else {
            return 0
        }
        return min(100, used / total * 100)
    }

    var usedPercentageString: String {
        (total > 0 ? used / total : 0).percentageString
    }

    /// Physical memory (GB), NOT the sum of the vm categories: speculative
    /// and other unclassified pages are missing from that sum, which used to
    /// shrink the denominator (inflated, jittery usage %) and made it 0/0 =
    /// NaN before the first sample.
    var total: Double {
        Self.physicalMemory
    }

    private static let physicalMemory = System.physicalMemory()

    var allFree: Double {
        max(0, total - used)
    }

    var freeString: String {
        max(0, total - used).memoryString
    }

    @objc func refresh() {
        (free, active, inactive, wired, compressed, appMemory, cachedFiles) = System.memoryUsage()
        temp = SmcControl.shared.memoryProximityTemperature
        getSwap()
        writeToContainer()
    }

    private func getSwap() {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else {
            swapUsed = 0
            swapTotal = 0
            return
        }
        // bytes -> GB to match the other memory figures
        swapUsed = Double(usage.xsu_used) / 1_073_741_824
        swapTotal = Double(usage.xsu_total) / 1_073_741_824
    }

    func writeToContainer() {
        guard WidgetReloader.shouldWrite(kind: MemoryEntry.kind) else {
            return
        }
        Container.set(MemoryEntry(used: used, total: total, temp: temp))
        WidgetReloader.requestReload(ofKind: MemoryEntry.kind)
    }

    init() {
        initObserver(for: .StoreShouldRefresh)
        // populate immediately — views used to read 0/0 for the first tick
        refresh()
    }
}
