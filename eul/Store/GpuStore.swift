//
//  GpuStore.swift
//  eul
//
//  Created by Gao Sun on 2021/1/23.
//  Copyright © 2021 Gao Sun. All rights reserved.
//

import Combine
import Foundation
import SwiftUI

class GpuStore: ObservableObject, Refreshable, @unchecked Sendable {
    private var activeCancellable: AnyCancellable?

    /// plain storage — @ObservedObject has no effect outside SwiftUI Views;
    /// activeComponents changes are subscribed explicitly below
    let componentsStore = SharedStore.components

    /// confines the heavy IOKit / system_profiler reads off the main thread
    private let sampleQueue = DispatchQueue(label: "eul.gpuStore", qos: .utility)
    private var isLoadingGPUs = false
    private var isSampling = false
    private var lastSampleAt = Date.distantPast

    @Published var gpus = [GPU]()
    @Published var gpuStatistics = [GPU.Statistic]()

    var usageAverage: Double? {
        #if arch(arm64)
            // single shared-die GPU; statistics carry no PCI ID to match against
            if let stat = gpuStatistics.first {
                return Double(stat.usagePercentage)
            }
        #endif
        let stats = gpus.compactMap { getStatustic(for: $0) }
        guard stats.count > 0 else {
            return nil
        }
        return Double(stats.reduce(0) { $0 + $1.usagePercentage }) / Double(stats.count)
    }

    var usageAverageString: String? {
        guard let average = usageAverage else {
            return nil
        }
        return "\(String(format: "%.0f", average))%"
    }

    var temperatureAverage: Double? {
        #if arch(arm64)
            if let temp = gpuStatistics.first?.temperature {
                return temp
            }
            if let temp = AppleSiliconSensors.shared?.gpuTemperature {
                return temp
            }
        #endif
        let temps = gpus.compactMap { getStatustic(for: $0)?.temperature }
        guard temps.count > 0 else {
            return nil
        }
        return temps.reduce(0) { $0 + $1 } / Double(temps.count)
    }

    func getStatustic(for gpu: GPU) -> GPU.Statistic? {
        #if arch(arm64)
            if gpu.deviceId.hasPrefix("apple-silicon-") {
                return gpuStatistics.first
            }
        #endif
        return gpuStatistics.first {
            $0.pciMatch.lowercased().contains(gpu.deviceId.deletingPrefix("0x"))
        }
    }

    init() {
        // GPU model/core count is an immutable hardware fact fetched via
        // system_profiler (0.5–2 s+). Loading it synchronously here used to
        // block the main thread during launch — do it off-main and publish.
        loadGPUs()
        initObserver(for: .StoreShouldRefresh)
        // refresh immediately to prevent "N/A"
        activeCancellable = componentsStore.$activeComponents
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    self?.refresh()
                }
            }
    }

    private func loadGPUs() {
        guard !isLoadingGPUs else {
            return
        }
        isLoadingGPUs = true
        sampleQueue.async { [weak self] in
            let gpus = GPU.getGPUs() ?? []
            DispatchQueue.main.async {
                self?.gpus = gpus
                self?.isLoadingGPUs = false
            }
        }
    }

    @objc func refresh() {
        guard
            componentsStore.activeComponents.contains(.GPU)
            // the panel reads this store regardless of pinned components
            || SharedStore.ui.menuOpened
        else {
            return
        }

        // The full accelerator property dump is the heaviest read in the
        // refresh chain (a single-key read returns stale data — see GPU.getInfo).
        // While the panel is closed the bar value moves slowly enough to halve
        // the cost: sample at most once per TWO ticks. Panel open = per-tick,
        // and the explicit refresh on panel open passes this gate immediately.
        if !SharedStore.ui.menuOpened {
            let tick = TimeInterval(max(1, SharedStore.preference.smcRefreshRate))
            if Date().timeIntervalSince(lastSampleAt) < tick * 2 - 0.5 {
                return
            }
        }

        // keep the full read off the main thread and only publish the result.
        // SMC temperature fallback is applied on main (SmcControl state is
        // main-thread).
        guard !isSampling else {
            return
        }
        isSampling = true
        lastSampleAt = Date()
        sampleQueue.async { [weak self] in
            let stats = GPU.getInfo() ?? []
            DispatchQueue.main.async {
                guard let self = self else {
                    return
                }
                let fallback = SmcControl.shared.gpuProximityTemperature
                self.gpuStatistics = stats.map { stat in
                    var stat = stat
                    if stat.temperature == nil {
                        stat.temperature = fallback
                    }
                    return stat
                }
                self.isSampling = false
            }
        }
    }
}
