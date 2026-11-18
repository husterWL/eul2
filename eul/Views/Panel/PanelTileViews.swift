//
//  PanelTileViews.swift
//  eul
//
//  One struct per panel tile, each declaring ONLY the stores it reads.
//  This is the granularity fix: when every tile lived inside PanelView's
//  single body (14 @EnvironmentObjects), any store's tick re-evaluated the
//  whole 900-line body. @EnvironmentObject subscribes to objectWillChange
//  regardless of which properties the body touches, so the split is what
//  makes per-tile invalidation real.
//

import Localize_Swift
import SharedLibrary
import SwiftUI

private var secondary: Color {
    DesignTokens.Surfaces.secondaryText
}

// MARK: - CPU

struct PanelCpuTile: View {
    @EnvironmentObject var cpuStore: CpuStore
    @EnvironmentObject var healthStore: HealthStore
    @EnvironmentObject var healthHistory: HealthHistoryStore
    @Binding var expanded: Bool

    private var isExpanded: Bool {
        expanded || healthStore.abnormalComponent == .CPU
    }

    var body: some View {
        let severity = healthStore.severity(for: .CPU)
        let tile = PanelTile(
            label: "component.cpu".localized().uppercased(),
            aux: cpuStore.temp?.temperatureString,
            severity: severity
        ) {
            RollingNumber(cpuStore.usage) { String(format: "%.0f%%", $0) }
                .font(DesignTokens.Typo.hero)
                .foregroundColor(severity.accent ?? .primary)
            Sparkline(values: healthHistory.cpuHistory, maxValue: 100, color: severity.accent ?? .primary, animation: Motion.reduceMotionEnabled ? nil : .eulTween)
                .frame(height: 22)
                .padding(.top, 2)
            Text(severity != .normal ? healthStore.verdictText : String(format: "panel.cores".localized(), cpuStore.logicalCores))
                .font(DesignTokens.Typo.sub)
                .foregroundColor(secondary)
                .padding(.top, 2)
            if isExpanded {
                PanelTileDivider()
                CoreGrid(usages: cpuStore.coreUsages, labels: cpuStore.coreLabels, accent: severity.accent)
                    .padding(.top, 8)
                Text("\("panel.load".localized()) \(cpuStore.loadAverage1MinString) · \(cpuStore.loadAverage5MinString) · \(cpuStore.loadAverage15MinString)\(cpuStore.upTimeString.map { "  ·  \(String(format: "panel.up".localized(), $0))" } ?? "")")
                    .font(DesignTokens.Typo.sub)
                    .foregroundColor(secondary)
                    .padding(.top, 8)
            }
        }
        tile.panelExpandable(label: "component.cpu".localized(), expanded: $expanded)
    }
}

// MARK: - Memory

struct PanelMemoryTile: View {
    @EnvironmentObject var memoryStore: MemoryStore
    @EnvironmentObject var healthStore: HealthStore
    @Binding var expanded: Bool

    var body: some View {
        let total = memoryStore.total
        // split into two fixed lines instead of one long run: at half width the
        // single line was truncated to "App 5.0 · Wired 2.2 · Co…"
        let sub = String(
            format: "%@ %.1f · %@ %.1f GB",
            "memory.app".localized(),
            memoryStore.appMemory,
            "memory.wired".localized(),
            memoryStore.wired
        )
        let sub2 = String(
            format: "%@ %.1f GB",
            "memory.compressed".localized(),
            memoryStore.compressed
        )
        let severity = healthStore.severity(for: .Memory)
        let tile = PanelTile(
            label: "component.memory".localized().uppercased(),
            aux: "\("memory.swap".localized()) \(memoryStore.swapUsed.memoryString)",
            severity: severity
        ) {
            RollingNumber(total > 0 ? memoryStore.usedPercentage : nil) { String(format: "%.0f%%", $0) }
                .font(DesignTokens.Typo.hero)
                .foregroundColor(severity.accent ?? .primary)
            SegmentBar(segments: total > 0 ? [
                (memoryStore.appMemory / total, 0.95),
                (memoryStore.wired / total, 0.5),
                (memoryStore.compressed / total, 0.28),
            ] : [])
            VStack(alignment: .leading, spacing: 1) {
                Text(sub)
                Text(sub2)
            }
            .font(DesignTokens.Typo.sub)
            .foregroundColor(secondary)
            .lineLimit(1)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 2)
            if expanded {
                PanelTileDivider()
                PanelDetailGrid(rows: [
                    ("memory.app".localized(), memoryStore.appMemory.memoryString),
                    ("memory.wired".localized(), memoryStore.wired.memoryString),
                    ("memory.compressed".localized(), memoryStore.compressed.memoryString),
                    ("memory.cached_files".localized(), memoryStore.cachedFiles.memoryString),
                    ("memory.free".localized(), memoryStore.allFree.memoryString),
                    ("memory.total".localized(), total.memoryString),
                    ("memory.swap".localized(), "\(memoryStore.swapUsed.memoryString) / \(memoryStore.swapTotal.memoryString)"),
                ])
                .padding(.top, 8)
            }
        }
        tile.panelExpandable(label: "component.memory".localized(), expanded: $expanded)
    }
}

// MARK: - Network

struct PanelNetworkTile: View {
    @EnvironmentObject var networkStore: NetworkStore
    @EnvironmentObject var healthHistory: HealthHistoryStore
    @EnvironmentObject var preferenceStore: PreferenceStore
    @Binding var expanded: Bool

    /// bits ⇄ bytes is a stored choice made in Settings · General · Units
    /// (design §4.7) and applied everywhere a rate renders
    private func rateText(_ bytesPerSecond: Double) -> some View {
        let inBits = preferenceStore.networkRateInBits
        // value and unit are derived from the same rolling number, so they can
        // never disagree mid-roll (e.g. a transient "900 MB/s" while the value
        // is still crossing the KB→MB boundary)
        return RollingValue(bytesPerSecond) { value in
            let parts = ByteUnit(value).readableParts(inBits: inBits)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(parts.value).font(DesignTokens.Typo.mid)
                Text("\(parts.unit)/s")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(secondary)
            }
        }
    }

    var body: some View {
        // NetworkPort.description handles the optional port name ("Wi-Fi (en0)")
        let aux = networkStore.currentActivePort.map { $0.description }
        let historyMax = max(healthHistory.networkHistory.max() ?? 1, 1)
        let tile = PanelTile(label: "component.network".localized().uppercased(), aux: aux) {
            HStack(spacing: 2) {
                Text("↓").foregroundColor(secondary).font(.system(size: 11))
                rateText(networkStore.inSpeedInByte)
            }
            HStack(spacing: 2) {
                Text("↑").foregroundColor(secondary).font(.system(size: 11))
                rateText(networkStore.outSpeedInByte)
            }
            Sparkline(values: healthHistory.networkHistory, maxValue: historyMax, animation: Motion.reduceMotionEnabled ? nil : .eulTween)
                .frame(height: 22)
                .padding(.top, 2)
            if expanded {
                PanelTileDivider()
                PanelDetailGrid(rows: [
                    ("panel.network.interface".localized(), aux ?? "network.no_activity".localized()),
                    ("network.total".localized(), ByteUnit(Double(networkStore.networkUsage.inBytes + networkStore.networkUsage.outBytes), kilo: 1000).readable),
                    ("panel.network.received".localized(), ByteUnit(Double(networkStore.networkUsage.inBytes), kilo: 1000).readable),
                    ("panel.network.sent".localized(), ByteUnit(Double(networkStore.networkUsage.outBytes), kilo: 1000).readable),
                ])
                .padding(.top, 8)
            }
        }
        tile.panelExpandable(label: "component.network".localized(), expanded: $expanded)
    }
}

// MARK: - GPU

struct PanelGpuTile: View {
    @EnvironmentObject var gpuStore: GpuStore
    @Binding var expanded: Bool

    /// computed property, not body-local statements: `body` is a ViewBuilder
    /// and imperative `if` side effects don't belong there
    private var subText: String {
        let gpu = gpuStore.gpus.first
        var sub = gpu?.model ?? "component.gpu".localized()
        if let cores = gpu?.cores {
            sub += " · " + String(format: "panel.cores".localized(), cores)
        }
        return sub
    }

    var body: some View {
        let gpu = gpuStore.gpus.first
        let tile = PanelTile(
            label: "component.gpu".localized().uppercased(),
            aux: gpuStore.temperatureAverage?.temperatureString
        ) {
            RollingNumber(gpuStore.usageAverage) { String(format: "%.0f%%", $0) }
                .font(DesignTokens.Typo.hero)
            Spacer(minLength: 0)
            Text(subText)
                .font(DesignTokens.Typo.sub)
                .foregroundColor(secondary)
                .lineLimit(1)
            if expanded {
                let statistic = gpuStore.gpuStatistics.first
                PanelTileDivider()
                PanelDetailGrid(rows: [
                    ("panel.gpu.model".localized(), gpu?.model ?? "N/A"),
                    ("panel.gpu.vendor".localized(), gpu?.vendor ?? "N/A"),
                    ("panel.gpu.cores".localized(), gpu?.cores.map(String.init) ?? "N/A"),
                    ("gpu.temperature".localized(), statistic?.temperature.map { $0.temperatureString } ?? "N/A"),
                    ("panel.gpu.clock".localized(), statistic?.coreClock.map { "\($0) MHz" } ?? "N/A"),
                    ("panel.gpu.memory_clock".localized(), statistic?.memoryClock.map { "\($0) MHz" } ?? "N/A"),
                ])
                .padding(.top, 8)
            }
        }
        tile.panelExpandable(label: "component.gpu".localized(), expanded: $expanded)
    }
}

// MARK: - Disk

struct PanelDiskTile: View {
    @EnvironmentObject var diskStore: DiskStore
    @EnvironmentObject var healthStore: HealthStore
    @Binding var expanded: Bool

    /// computed property — imperative if/else assignment isn't valid in a
    /// ViewBuilder body
    private var usedFraction: Double {
        if let ceiling = diskStore.ceilingBytes, let free = diskStore.freeBytes, ceiling > 0 {
            return Double(ceiling - free) / Double(ceiling)
        }
        return 0
    }

    var body: some View {
        let severity = healthStore.severity(for: .Disk)
        let isAllDisks = diskStore.config.diskSelection == EulComponentConfig.allDisksSelection

        let tile = PanelTile(
            label: "component.disk".localized().uppercased(),
            aux: diskStore.usagePercentageString,
            severity: severity
        ) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                RollingNumber(diskStore.freeBytes.map { Double($0) }) { ByteUnit($0, kilo: 1000).readable }
                    .font(Font.system(size: 19, weight: .semibold).monospacedDigit())
                    .foregroundColor(severity.accent ?? .primary)
                Text("text_component.free".localized().lowercased())
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(secondary)
            }
            SegmentBar(segments: [(usedFraction, 0.95)])
            Text(String(format: "panel.of".localized(), diskStore.totalString))
                .font(DesignTokens.Typo.sub)
                .foregroundColor(secondary)
                .padding(.top, 2)

            // volume names stay in the compact tile unless the expanded layer
            // already lists them with their per-volume figures
            if !expanded, isAllDisks, let disks = diskStore.list?.disks {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(disks) { disk in
                        Text(disk.name)
                            .font(.system(size: 10))
                            .lineLimit(1)
                    }
                }
                .padding(.top, 4)
            }
            if expanded {
                PanelTileDivider()
                PanelDetailGrid(rows: [
                    ("text_component.usage".localized(), diskStore.usageString),
                    ("panel.disk.applications".localized(), diskStore.applicationsString),
                    ("panel.disk.system_data".localized(), diskStore.systemDataString),
                    ("text_component.free".localized(), diskStore.freeString),
                    ("text_component.total".localized(), diskStore.totalString),
                ])
                .padding(.top, 8)
                // one off-main walk of /Applications per app run
                .onAppear { diskStore.measureApplicationsIfNeeded() }
                if let disks = diskStore.list?.disks, !disks.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(disks) { disk in
                            HStack(spacing: 6) {
                                Text(disk.name)
                                    .font(.system(size: 10))
                                    .lineLimit(1)
                                Spacer(minLength: 4)
                                Text("\(disk.usedSizeString) / \(disk.sizeString)")
                                    .font(Font.system(size: 10).monospacedDigit())
                                    .foregroundColor(secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    .padding(.top, 6)
                }
            }
        }
        tile.panelExpandable(label: "component.disk".localized(), expanded: $expanded)
    }
}

// MARK: - Fans

/// Readings always; the control surface lives in the expanded state —
/// intervention happens next to the temperatures that justify it (§2.7).
/// On macOS < 13 there is nothing to expand: plain readings, no tap
/// affordance, no teaser (absent, never gray).
struct PanelFansTile: View {
    @EnvironmentObject var fanStore: FanStore
    @EnvironmentObject var fanControl: FanControlStore
    @Binding var expanded: Bool

    private var fanModeText: String {
        let modes = Set(fanControl.overrides.values.map { $0.mode })
        if modes.isEmpty {
            return "fan.mode.auto".localized()
        }
        if modes == [.boost] {
            return "fan.mode.boost".localized()
        }
        return "fan.mode.manual".localized()
    }

    private var fanReadings: some View {
        ForEach(fanStore.fans) { fan in
            HStack(spacing: 4) {
                Text("\(fan.id + 1)")
                    .font(.system(size: 11))
                    .foregroundColor(secondary)
                RollingNumber(fan.currentSpeed.map(Double.init)) { "\(Int($0)) rpm" }
                    .font(DesignTokens.Typo.mid)
            }
        }
    }

    var body: some View {
        let controllable = fanControl.status != .unsupportedOS
        let isExpanded = expanded && controllable
        // an unreachable helper means the controls would silently no-op —
        // the tile carries the cue so the repair affordance gets found
        let severity: HealthLevel = fanControl.status == .enabled && fanControl.helperUnreachable ? .elevated : .normal
        let tile = PanelTile(label: "component.fan".localized().uppercased(), aux: fanModeText, severity: severity) {
            if !isExpanded {
                fanReadings
                Spacer(minLength: 0)
                Text(fanControl.status == .enabled && fanControl.overrideActive
                    ? "fan.control.override".localized()
                    : "panel.fans.system_managed".localized())
                    .font(DesignTokens.Typo.sub)
                    .foregroundColor(secondary)
            } else {
                if fanControl.status != .enabled {
                    fanReadings
                }
                PanelTileDivider()
                FanControlSurface()
                    .padding(.top, 2)
            }
        }
        if controllable {
            tile.panelExpandable(label: "component.fan".localized(), expanded: $expanded)
        } else {
            tile
        }
    }
}

// MARK: - Battery

struct PanelBatteryTile: View {
    @EnvironmentObject var batteryStore: BatteryStore
    @Binding var expanded: Bool

    var body: some View {
        // the one display-only cue: shared with the bar slot via BatteryStore
        let severity = batteryStore.severity
        let tile = PanelTile(
            label: "component.battery".localized().uppercased(),
            aux: batteryStore.timeRemaining,
            severity: severity
        ) {
            RollingNumber(batteryStore.charge) { $0.percentageString }
                .font(DesignTokens.Typo.hero)
                .foregroundColor(severity.accent ?? .primary)
            Spacer(minLength: 0)
            Text(String(format: "panel.battery.sub".localized(), batteryStore.healthString, "\(batteryStore.cycleCount)"))
                .font(DesignTokens.Typo.sub)
                .foregroundColor(secondary)
                .lineLimit(1)
            if expanded {
                PanelTileDivider()
                PanelDetailGrid(rows: [
                    ("battery.max_capacity".localized(), batteryStore.maxCapacityText),
                    ("battery.design_capacity".localized(), batteryStore.designCapacityText),
                    ("battery.condition".localized(), batteryStore.io.condition.description),
                    ("battery.power_source".localized(), batteryStore.io.powerSource.description),
                ])
                .padding(.top, 8)
            }
        }
        tile.panelExpandable(label: "component.battery".localized(), expanded: $expanded)
    }
}

// MARK: - Bluetooth

struct PanelBluetoothTile: View {
    let devices: [BluetoothDevice]

    private func deviceDescription(_ device: BluetoothDevice) -> String {
        if device.batteryPercentLeft != nil || device.batteryPercentRight != nil || device.batteryPercentCase != nil {
            var parts: [String] = []
            if let left = device.batteryPercentLeft {
                parts.append("L \(left)")
            }
            if let right = device.batteryPercentRight {
                parts.append("R \(right)")
            }
            if let casePercent = device.batteryPercentCase {
                parts.append("C \(casePercent)")
            }
            return parts.joined(separator: " · ")
        }
        return device.batteryPercent.map { "\($0)%" } ?? ""
    }

    var body: some View {
        PanelTile(
            label: "component.bluetooth".localized().uppercased(),
            aux: "\(devices.count)"
        ) {
            ForEach(devices.prefix(2), id: \.address) { device in
                VStack(alignment: .leading, spacing: 0) {
                    Text(device.name)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                    Text(deviceDescription(device))
                        .font(DesignTokens.Typo.sub)
                        .foregroundColor(secondary)
                }
            }
            Spacer(minLength: 0)
        }
    }
}
