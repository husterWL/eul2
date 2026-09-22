//
//  DiskStore.swift
//  eul
//
//  Created by Gao Sun on 2020/11/1.
//  Copyright © 2020 Gao Sun. All rights reserved.
//

import Combine
import Foundation
import SharedLibrary
import SwiftUI

class DiskStore: ObservableObject, Refreshable {
    private var activeCancellable: AnyCancellable?

    @ObservedObject var componentsStore = SharedStore.components
    var config: EulComponentConfig {
        SharedStore.componentConfig[EulComponent.Disk]
    }

    @Published var list: DiskList?

    var selectedDisk: DiskList.Disk? {
        guard config.diskSelection != "", config.diskSelection != EulComponentConfig.allDisksSelection else {
            return nil
        }
        return list?.disks.filter { $0.name == config.diskSelection }.first
    }

    /// When "All" is selected, return aggregated stats for all disks
    var allDisksStats: (total: UInt64, free: UInt64)? {
        guard config.diskSelection == EulComponentConfig.allDisksSelection,
              let disks = list?.disks
        else {
            return nil
        }
        let total = disks.reduce(UInt64(0)) { $0 + $1.size }
        let free = disks.reduce(UInt64(0)) { $0 + $1.freeSize }
        return (total, free)
    }

    /// With no explicit selection, report the boot volume instead of summing
    /// every mounted volume — APFS volumes share one container, so the sum
    /// counted the same space several times (#250, #182).
    private var rootVolume: (size: UInt64, free: UInt64)?
    private var rootVolumeReadAt: Date?
    /// the boot-volume capacity query is an XPC round trip measured at ~4.7 ms
    /// — far too much for a figure that moves slowly, so it is re-read on this
    /// cadence instead of every tick
    private static let rootVolumeInterval: TimeInterval = 60

    private static func readRootVolume() -> (size: UInt64, free: UInt64)? {
        let url = URL(fileURLWithPath: "/")
        guard
            let values = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]),
            let size = values.volumeTotalCapacity, size >= 0,
            let free = values.volumeAvailableCapacityForImportantUsage, free >= 0
        else {
            return nil
        }
        return (UInt64(size), UInt64(free))
    }

    var ceilingBytes: UInt64? {
        if let allStats = allDisksStats {
            return allStats.total
        }
        return selectedDisk.map { $0.size } ?? rootVolume?.size
    }

    var freeBytes: UInt64? {
        if let allStats = allDisksStats {
            return allStats.free
        }
        return selectedDisk.map { $0.freeSize } ?? rootVolume?.free
    }

    var usageString: String {
        guard let ceiling = ceilingBytes, let free = freeBytes else {
            return "N/A"
        }
        return ByteUnit(ceiling - free, kilo: 1000).readable
    }

    var usagePercentageString: String {
        guard let ceiling = ceilingBytes, let free = freeBytes else {
            return "N/A"
        }
        return (Double(ceiling - free) / Double(ceiling)).percentageString
    }

    var freeString: String {
        guard let free = freeBytes else {
            return "N/A"
        }
        return ByteUnit(free, kilo: 1000).readable
    }

    var totalString: String {
        guard let ceiling = ceilingBytes else {
            return "N/A"
        }
        return ByteUnit(ceiling, kilo: 1000).readable
    }

    // MARK: measured storage categories

    /// macOS keeps the Storage breakdown (Applications / System Data / …) in a
    /// private daemon with no public API, so this split is measured rather than
    /// reported: the applications folder is walked on demand and whatever the
    /// volume has used beyond it is presented as the system-data estimate. The
    /// walk costs ~1.8 s of CPU, so it runs once per app run, off the main
    /// thread, and only when the disk tile is expanded.
    @Published private(set) var applicationsBytes: UInt64?
    @Published private(set) var hasMeasuredApplications = false
    private static let measureQueue = DispatchQueue(label: "eul.diskMeasurement", qos: .utility)

    var usedBytes: UInt64? {
        guard let ceiling = ceilingBytes, let free = freeBytes, ceiling >= free else {
            return nil
        }
        return ceiling - free
    }

    var applicationsString: String {
        if let applicationsBytes = applicationsBytes {
            return ByteUnit(applicationsBytes, kilo: 1000).readable
        }
        return hasMeasuredApplications ? "N/A" : "…"
    }

    /// Remainder after the applications folder. Clamped at zero because the
    /// volume's free-space figure already subtracts purgeable space, which can
    /// make the measured folder look larger than the total used space.
    var systemDataBytes: UInt64? {
        guard let used = usedBytes, let applications = applicationsBytes else {
            return nil
        }
        return used > applications ? used - applications : 0
    }

    var systemDataString: String {
        guard let systemDataBytes = systemDataBytes else {
            return hasMeasuredApplications ? "N/A" : "…"
        }
        return ByteUnit(systemDataBytes, kilo: 1000).readable
    }

    /// One walk per app run, off-main: hundreds of bundles take ~1.8 s of CPU,
    /// which would stall a panel layout pass if it ran inline.
    func measureApplicationsIfNeeded() {
        guard !hasMeasuredApplications else {
            return
        }
        hasMeasuredApplications = true
        Self.measureQueue.async { [weak self] in
            let bytes = Self.allocatedSize(of: URL(fileURLWithPath: "/Applications"))
            DispatchQueue.main.async {
                self?.applicationsBytes = bytes
            }
        }
    }

    private static func allocatedSize(of url: URL) -> UInt64? {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        // unreadable entries are skipped rather than aborting the whole walk
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { _, _ in true }
        ) else {
            return nil
        }
        let keySet = Set(keys)
        var total: UInt64 = 0
        for case let fileURL as URL in enumerator {
            guard
                let values = try? fileURL.resourceValues(forKeys: keySet),
                values.isRegularFile == true,
                let size = values.totalFileAllocatedSize
            else {
                continue
            }
            total += UInt64(size)
        }
        return total
    }

    @objc func refresh() {
        guard
            componentsStore.activeComponents.contains(.Disk)
            // the panel reads this store regardless of pinned components
            || SharedStore.ui.menuOpened
        else {
            return
        }

        // The no-selection fallback needs the boot volume's capacity, but that
        // query is an XPC round trip (~4.7 ms), so it is re-read on a slow
        // cadence. A selected volume ejecting still nils selectedDisk within
        // one tick, and this refresh then picks the fallback back up.
        let now = Date()
        let rootVolumeIsStale = rootVolumeReadAt.map { now.timeIntervalSince($0) >= Self.rootVolumeInterval } ?? true
        if selectedDisk == nil, rootVolumeIsStale {
            rootVolume = Self.readRootVolume()
            rootVolumeReadAt = now
        }
        loadDisks()
    }

    /// ungated volume enumeration — the settings Data Sources picker needs
    /// the list even when no Disk component is pinned and the panel is closed
    func loadDisks() {
        guard let volumes = (try? FileManager.default.contentsOfDirectory(atPath: DiskList.volumesPath)) else {
            list = nil
            return
        }

        list = DiskList(disks: volumes.compactMap {
            if $0.starts(with: ".") || $0.contains("com.apple") { return nil }

            let path = DiskList.pathForName($0)

            guard
                let attributes = try? FileManager.default.attributesOfFileSystem(forPath: path),
                let size = attributes[FileAttributeKey.systemSize] as? UInt64,
                let freeSize = attributes[FileAttributeKey.systemFreeSize] as? UInt64
            else {
                return nil
            }

            return DiskList.Disk(
                name: $0,
                size: size,
                freeSize: freeSize
            )
        })
    }

    init() {
        initObserver(for: .StoreShouldRefresh)
        // refresh immediately to prevent "N/A"
        activeCancellable = componentsStore.$activeComponents
            .sink { _ in
                DispatchQueue.main.async {
                    self.refresh()
                }
            }
    }
}
