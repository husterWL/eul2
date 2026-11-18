//
//  NetworkTopStore.swift
//  eul
//
//  Created by Gao Sun on 2020/10/17.
//  Copyright © 2020 Gao Sun. All rights reserved.
//

import AppKit
import Combine
import SwiftUI

class NetworkTopStore: ObservableObject, @unchecked Sendable {
    struct NetworkSpeed: CustomStringConvertible {
        var inSpeedInByte: Double = 0
        var outSpeedInByte: Double = 0
        var inTotalByte: Double = 0
        var outTotalByte: Double = 0

        var totalByte: Double {
            inTotalByte + outTotalByte
        }

        var description: String {
            let input = inSpeedInByte >= 1e6
                ? String(format: "%.1f MB/s", inSpeedInByte / 1e6)
                : String(format: "%.0f KB/s", inSpeedInByte / 1e3)
            let output = outSpeedInByte >= 1e6
                ? String(format: "%.1f MB/s", outSpeedInByte / 1e6)
                : String(format: "%.0f KB/s", outSpeedInByte / 1e3)
            return "↓ \(input) ↑ \(output)"
        }
    }

    struct ProcessNetworkUsage: ProcessUsage {
        typealias T = NetworkSpeed
        let pid: Int
        let command: String
        let value: NetworkSpeed
        let runningApp: NSRunningApplication?
    }

    private var timer: Timer?
    private var activeCancellable: AnyCancellable?
    private var rateCancellable: AnyCancellable?
    private var isActive = false
    /// confines lastInBytes/lastOutBytes/lastTimestamp: run() executes here,
    /// and the reset in update(shouldStart:) hops here too, so a lens toggle
    /// can't race an in-flight nettop sample
    private let sampleQueue = DispatchQueue(label: "eul.networkTop")
    private var lastTimestamp: TimeInterval = Date().timeIntervalSince1970
    private var lastInBytes: [Int: Double] = [:]
    private var lastOutBytes: [Int: Double] = [:]
    // plain storage, NOT @ObservedObject — that property wrapper only has
    // observation semantics inside SwiftUI Views; in a plain class it does
    // nothing. Rate changes are subscribed explicitly below.
    let preferenceStore = SharedStore.preference
    @Published var processes: [ProcessNetworkUsage] = []

    private var interval: Int {
        preferenceStore.networkRefreshRate
    }

    var totalSpeed: NetworkSpeed {
        processes.reduce(into: NetworkSpeed()) { result, usage in
            result.inSpeedInByte += usage.value.inSpeedInByte
            result.outSpeedInByte += usage.value.outSpeedInByte
        }
    }

    private func run() {
        guard let string = shell("nettop -L 1 -P -x -J bytes_in,bytes_out 2>/dev/null") else {
            print("unable to fetch network activity, please make sure nettop is available")
            return
        }

        let rows = string.split(separator: "\n").map { String($0) }
        // nettop can exit 0 with empty stdout — never index rows[0] blindly
        guard let headerRow = rows.first else {
            return
        }
        let headers = headerRow
            .split(separator: ",", omittingEmptySubsequences: false)
            .map { String($0.lowercased()) }
        let processIndex = 0

        guard
            let inBytesIndex = headers.firstIndex(of: "bytes_in"),
            let outBytesIndex = headers.firstIndex(of: "bytes_out")
        else {
            return
        }

        let time = Date().timeIntervalSince1970
        let timeElapsed = time - lastTimestamp
        lastTimestamp = time
        // a zero/near-zero elapsed would divide by ~0 and fabricate a spike
        let canDiff = timeElapsed > 0.1

        Print("network top is updating")
        var livePids = Set<Int>()
        let updated = rows.dropFirst().compactMap { row -> ProcessNetworkUsage? in
            // keep empty fields so columns stay aligned with the header
            // (omitting them shifts every later column left)
            let cols = row.split(separator: ",", omittingEmptySubsequences: false).map { String($0) }

            guard
                cols.indices.contains(processIndex),
                cols.indices.contains(inBytesIndex),
                cols.indices.contains(outBytesIndex)
            else {
                return nil
            }

            let processCol = cols[processIndex]
            let splitted = processCol.split(separator: ".").map { String($0) }

            guard
                let last = splitted.last,
                let pid = Int(last),
                let inBytes = Double(cols[inBytesIndex]),
                let outBytes = Double(cols[outBytesIndex])
            else {
                return nil
            }

            let totalBytes = inBytes + outBytes

            guard totalBytes > 0 else {
                return nil
            }

            livePids.insert(pid)
            let lastIn = lastInBytes[pid]
            let lastOut = lastOutBytes[pid]

            lastInBytes[pid] = inBytes
            lastOutBytes[pid] = outBytes

            let speed = NetworkSpeed(
                inSpeedInByte: canDiff ? (lastIn.map { $0 > inBytes ? 0 : (inBytes - $0) / timeElapsed } ?? 0) : 0,
                outSpeedInByte: canDiff ? (lastOut.map { $0 > outBytes ? 0 : (outBytes - $0) / timeElapsed } ?? 0) : 0,
                inTotalByte: inBytes,
                outTotalByte: outBytes
            )

            // reverse-DNS names (com.apple.WebKit.WebContent.123) must keep
            // everything but the trailing pid — splitting on "." and taking
            // [0] used to label them all "com"
            let command = splitted.count > 1
                ? splitted.dropLast().joined(separator: ".")
                : processCol

            return ProcessNetworkUsage(
                pid: pid,
                command: command,
                value: speed,
                runningApp: nil
            )
        }
        .sorted(by: { $0.value.totalByte > $1.value.totalByte })

        // drop baselines for pids no longer present: the dictionaries used to
        // grow without bound, and a reused pid inherited a dead process's
        // counters (one fabricated delta)
        lastInBytes = lastInBytes.filter { livePids.contains($0.key) }
        lastOutBytes = lastOutBytes.filter { livePids.contains($0.key) }

        DispatchQueue.main.async {
            self.processes = updated
        }
    }

    func update(shouldStart: Bool) {
        isActive = shouldStart
        guard shouldStart else {
            timer?.invalidate()
            timer = nil
            return
        }

        if timer != nil {
            Print("network task already started")
            return
        }

        sampleQueue.async { [weak self] in
            guard let self else {
                return
            }
            self.lastInBytes.removeAll()
            self.lastOutBytes.removeAll()
            self.lastTimestamp = Date().timeIntervalSince1970
        }
        processes = []

        let timer = Timer.scheduledTimer(withTimeInterval: Double(max(1, interval)), repeats: true) { [weak self] _ in
            // strong immutable shadow: the nested @Sendable closure must not
            // reference the weak `var` capture (Swift 6)
            guard let self else {
                return
            }
            // Run off-main — shell("nettop ...") is blocking; the serial
            // queue also prevents overlapping samples
            self.sampleQueue.async {
                self.run()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    init() {
        // open-only contract, lens-refined: nettop polls only while the
        // panel is open with the network lens selected (design §2.6)
        activeCancellable = Publishers
            .CombineLatest(
                SharedStore.ui.$panelLens,
                SharedStore.ui.$menuOpened
            )
            .map {
                $0 == .network && $1
            }
            .removeDuplicates()
            .sink { [weak self] in
                self?.update(shouldStart: $0)
            }

        // the sample interval used to be frozen at timer creation — changing
        // the refresh-rate preference while the panel was open did nothing
        // until the panel was closed and reopened
        rateCancellable = preferenceStore.$networkRefreshRate
            .removeDuplicates()
            .sink { [weak self] _ in
                guard let self = self, self.isActive else {
                    return
                }
                self.timer?.invalidate()
                self.timer = nil
                self.update(shouldStart: true)
            }
    }
}
