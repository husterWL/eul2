//
//  TopStore.swift
//  eul
//
//  Created by Jevon Mao on 1/22/21.
//  Copyright © 2021 Gao Sun. All rights reserved.
//

import AppKit
import Combine
import Foundation
import SwiftUI
import SystemKit

/// The panel's process lists, sampled straight from libproc.
///
/// This used to spawn `top -l 0` per lens and parse its text output, which tied
/// the numbers to the system locale and to `top`'s column layout. One
/// `proc_pidinfo` walk now returns resident memory and cumulative CPU time for
/// every process at once, so both lenses come from a single sample — and the CPU
/// figure keeps `top`'s core-equivalent scale (1.0 = one core, so a process can
/// exceed 100).
class TopStore: ObservableObject {
    /// matches the process section's visible row count
    private static let rowCount = 5
    /// below this a percentage is noise; `top` filtered the same way
    private static let minimumCPUPercentage = 0.1

    /// decimal megabytes, matching how the rest of the panel reports memory
    private let memorySizeMB = System.physicalMemory() * 1000

    private var timer: Timer?
    private var lensCancellable: AnyCancellable?
    /// confines previousCPU/lastSampleAt to the sampling queue so a lens toggle
    /// cannot race an in-flight walk
    private let sampleQueue = DispatchQueue(label: "eul.topStore")
    private var previousCPU: [pid_t: Double] = [:]
    private var lastSampleAt: Date?

    @ObservedObject var preferenceStore = SharedStore.preference
    @Published var cpuTopProcesses: [ProcessCpuUsage] = []
    @Published var ramTopProcesses: [RamUsage] = []

    private var interval: TimeInterval {
        TimeInterval(preferenceStore.smcRefreshRate)
    }

    /// One walk per tick feeds both lists.
    private func sample() {
        let samples = IOHelper.processSamples()
        let now = Date()
        let elapsed = lastSampleAt.map { now.timeIntervalSince($0) } ?? 0
        lastSampleAt = now

        // cumulative CPU time only becomes a rate against a previous reading, so
        // the first pass establishes the baseline and reports no percentages
        var rates: [pid_t: Double] = [:]
        if elapsed > 0 {
            for sample in samples {
                guard let previous = previousCPU[sample.pid] else {
                    continue
                }
                let delta = sample.cpuSeconds - previous
                // a negative delta means the pid was reused between samples
                guard delta >= 0 else {
                    continue
                }
                rates[sample.pid] = delta / elapsed * 100
            }
        }
        previousCPU = Dictionary(samples.map { ($0.pid, $0.cpuSeconds) }, uniquingKeysWith: { $1 })

        let cpu = samples
            .compactMap { sample -> (sample: IOHelper.ProcessSample, rate: Double)? in
                guard let rate = rates[sample.pid], rate >= Self.minimumCPUPercentage else {
                    return nil
                }
                return (sample, rate)
            }
            .sorted { $0.rate > $1.rate }
            .prefix(Self.rowCount)
        let ram = samples
            .sorted { $0.residentBytes > $1.residentBytes }
            .prefix(Self.rowCount)

        DispatchQueue.main.async { [self] in
            let apps = Dictionary(
                NSWorkspace.shared.runningApplications.map { ($0.processIdentifier, $0) },
                uniquingKeysWith: { $1 }
            )
            cpuTopProcesses = cpu.map {
                ProcessCpuUsage(
                    pid: Int($0.sample.pid),
                    command: $0.sample.name,
                    value: $0.rate,
                    runningApp: apps[$0.sample.pid]
                )
            }
            ramTopProcesses = ram.map {
                let megabytes = Double($0.residentBytes) / 1_000_000
                return RamUsage(
                    pid: Int($0.pid),
                    command: $0.name,
                    value: 100 * (megabytes / memorySizeMB),
                    usageAmount: megabytes,
                    runningApp: apps[$0.pid]
                )
            }
        }
    }

    func update(shouldStart: Bool) {
        guard shouldStart else {
            timer?.invalidate()
            timer = nil
            return
        }
        guard timer == nil else {
            return
        }

        sampleQueue.async { [weak self] in
            self?.previousCPU.removeAll()
            self?.lastSampleAt = nil
            // take the baseline immediately so the first tick can report
            self?.sample()
        }

        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.sampleQueue.async {
                self?.sample()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    init() {
        // the open-only contract (design §2.6) shared by both process lenses:
        // the walk runs only while the panel is open on CPU or memory
        lensCancellable = Publishers
            .CombineLatest(
                SharedStore.ui.$panelLens,
                SharedStore.ui.$menuOpened
            )
            .map { ($0 == .cpu || $0 == .memory) && $1 }
            .removeDuplicates()
            .sink { [weak self] in
                self?.update(shouldStart: $0)
            }
    }
}
