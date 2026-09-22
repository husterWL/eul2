//
//  PanelView.swift
//  eul
//
//  Created by Gao Sun on 2026/6/10.
//  Copyright © 2026 Gao Sun. All rights reserved.
//

import SharedLibrary
import SwiftUI

/// eul's own footprint, reported on every panel open — energy honesty as a
/// feature (design §2.6 footer)
private final class SelfUsageSampler: ObservableObject {
    @Published var percentString = "–"
    private var last: (date: Date, cpuSeconds: Double)?

    func sample() {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else {
            return
        }
        let cpuSeconds = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6
            + Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6
        let now = Date()
        guard let previous = last else {
            last = (now, cpuSeconds)
            return
        }
        let elapsed = now.timeIntervalSince(previous.date)
        guard elapsed > 0.5 else {
            return
        }
        percentString = String(format: "%.1f%%", max((cpuSeconds - previous.cpuSeconds) / elapsed * 100, 0))
        last = (now, cpuSeconds)
    }
}

/// The investigation panel (design §2.6): replaces the dropdown. Reads
/// top-down — verdict, tiles (the abnormal one carries the only color),
/// processes, footprint. Answers "why" in at most two interactions.
struct PanelView: View, SizeChangeView {
    @EnvironmentObject var uiStore: UIStore
    @EnvironmentObject var healthStore: HealthStore
    @EnvironmentObject var cpuStore: CpuStore
    @EnvironmentObject var memoryStore: MemoryStore
    @EnvironmentObject var networkStore: NetworkStore
    @EnvironmentObject var gpuStore: GpuStore
    @EnvironmentObject var diskStore: DiskStore
    @EnvironmentObject var fanStore: FanStore
    @EnvironmentObject var batteryStore: BatteryStore
    @EnvironmentObject var bluetoothStore: BluetoothStore
    @EnvironmentObject var topStore: TopStore
    @EnvironmentObject var networkTopStore: NetworkTopStore
    @EnvironmentObject var preferenceStore: PreferenceStore
    @EnvironmentObject var fanControl: FanControlStore

    @StateObject private var selfUsage = SelfUsageSampler()
    @State private var cpuExpanded = false
    @State private var fansExpanded = false
    @State private var memoryExpanded = false
    @State private var networkExpanded = false
    @State private var gpuExpanded = false
    @State private var diskExpanded = false
    @State private var batteryExpanded = false

    var onSizeChange: ((CGSize) -> Void)?

    private var secondary: Color {
        Color.primary.opacity(0.55)
    }

    private var cpuIsExpanded: Bool {
        cpuExpanded || healthStore.abnormalComponent == .CPU
    }

    /// Expansion is a layout change, so it honours Reduce Motion the same way
    /// the tweened readings do (§5.5).
    private func toggleExpansion(_ expanded: Binding<Bool>) {
        if Motion.reduceMotionEnabled {
            expanded.wrappedValue.toggle()
        } else {
            withAnimation(.eulTween) {
                expanded.wrappedValue.toggle()
            }
        }
    }

    /// Tap-to-expand affordance shared by the reading tiles: the compact size
    /// answers "how am I doing", the expanded size answers "what exactly".
    private func expandableTile(_ label: String, _ expanded: Binding<Bool>, _ tile: some View) -> some View {
        tile
            .contentShape(Rectangle())
            .onTapGesture {
                toggleExpansion(expanded)
            }
            .pointingHandCursor()
            .a11yExpandButton(label: label)
    }

    // MARK: header

    private var verdictColor: Color {
        switch healthStore.level {
        case .normal:
            return .primary
        case .elevated:
            return DesignTokens.Health.elevated
        case .critical:
            return DesignTokens.Health.critical
        }
    }

    private var subtitleText: String {
        guard let upTime = cpuStore.upTimeString else {
            return ""
        }
        return String(format: "panel.up".localized(), upTime)
    }

    /// update discovery moved here from the deleted bar badge/menu header
    /// (1.x .showInStatusBar) — the panel is the new surface
    private var showUpdateRow: Bool {
        preferenceStore.upgradeMethod != .none && preferenceStore.isUpdateAvailable == true
    }

    /// compact icon action (Clean / Preferences / Quit) — square so three fit
    /// where one text pill used to, leaving the title column room to breathe.
    /// The symbol carries a tooltip + a11y label since the word is gone.
    private func headerIcon(_ symbol: String, label: String, tint: Color, background: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(tint)
                .frame(width: 24, height: 22)
        }
        .buttonStyle(PlainButtonStyle())
        .background(background)
        .cornerRadius(6)
        .pointingHandCursor()
        .help(label)
        .accessibilityLabel(Text(label))
    }

    private var titleRow: some View {
        HStack(spacing: 10) {
            EyesGlyph(state: healthStore.glyphState, width: 17)
            VStack(alignment: .leading, spacing: 1) {
                Text(healthStore.verdictText)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(verdictColor)
                    .fixedSize(horizontal: false, vertical: true)
                if !subtitleText.isEmpty {
                    Text(subtitleText)
                        .font(.system(size: 11))
                        .foregroundColor(secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            // both actions one click away, no submenu; quit is immediate —
            // the helper's revert machinery makes quitting always safe
            HStack(spacing: 6) {
                headerIcon("sparkles", label: "clean_mode.action".localized(), tint: secondary, background: Color.primary.opacity(0.08)) {
                    AppDelegate.enterCleanMode()
                }
                headerIcon("gearshape", label: "menu.preferences".localized(), tint: secondary, background: Color.primary.opacity(0.08)) {
                    AppDelegate.openPreferences()
                }
                headerIcon("power", label: "menu.quit".localized(), tint: DesignTokens.Health.critical, background: DesignTokens.Health.critical.opacity(0.12)) {
                    AppDelegate.quit()
                }
            }
            .fixedSize()
        }
    }

    private var runawayCard: some View {
        guard healthStore.activeSignal == .runaway, let pid = healthStore.runawayCulpritPid else {
            return AnyView(EmptyView())
        }
        let duration = Int(healthStore.runawayDuration)
        let detail = "\(healthStore.runawayCulprit ?? "?") · PID \(pid) · \(duration / 60)m \(duration % 60)s"
        return AnyView(
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(DesignTokens.Health.elevated)
                VStack(alignment: .leading, spacing: 2) {
                    Text("health.runaway".localized())
                        .font(.system(size: 11, weight: .semibold))
                    Text(detail)
                        .font(.system(size: 10).monospaced())
                        .foregroundColor(secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Text("health.runaway.explain".localized())
                    .font(.system(size: 10))
                    .foregroundColor(secondary)
                    .multilineTextAlignment(.trailing)
            }
            .padding(9)
            .background(DesignTokens.Health.elevated.opacity(0.10))
            .cornerRadius(7)
        )
    }

    /// update discovery and the fan-override notice are panel-wide rows below
    /// the title — at this width they would wrap if squeezed beside the buttons
    private func updateRow(_ url: URL) -> some View {
        Button(action: {
            NSWorkspace.shared.open(url)
        }) {
            Text("\("ui.new_version".localized()) — \("ui.download".localized())")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(Color.accentColor)
        }
        .buttonStyle(PlainButtonStyle())
        .pointingHandCursor()
    }

    /// an active override must be impossible to forget (§2.7) — its own row
    /// with one-click revert
    private var overrideRow: some View {
        HStack(spacing: 6) {
            Text("\("fan.control.override".localized()) · \(fanControl.overrideMinutes)m")
                .lineLimit(1)
            Spacer(minLength: 8)
            Button(action: {
                fanControl.revertAllToAuto()
            }) {
                Text("fan.control.revert".localized())
                    .underline()
                    .lineLimit(1)
            }
            .buttonStyle(PlainButtonStyle())
            .pointingHandCursor()
            .fixedSize()
        }
        .font(.system(size: 10.5))
        .foregroundColor(secondary)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 7) {
            titleRow
            if showUpdateRow, let url = preferenceStore.latestReleaseURL {
                updateRow(url)
            }
            if fanControl.overrideActive {
                overrideRow
            }
        }
        .padding(EdgeInsets(top: 2, leading: 4, bottom: 12, trailing: 4))
    }

    // MARK: tiles

    private func tileDivider() -> some View {
        Rectangle()
            .fill(Color.primary.opacity(0.09))
            .frame(height: 1)
            .padding(.top, 6)
    }

    /// a tile's color cue comes from the health engine — sustained, debounced
    /// signals, never a raw sample (§2.4) — at the engine's current level
    private func tileSeverity(_ component: EulComponent) -> HealthLevel {
        healthStore.abnormalComponent == component ? healthStore.level : .normal
    }

    private func cpuTile() -> some View {
        let severity = tileSeverity(.CPU)
        let tile = PanelTile(
            label: "component.cpu".localized().uppercased(),
            aux: cpuStore.temp?.temperatureString,
            severity: severity
        ) {
            RollingNumber(cpuStore.usage) { String(format: "%.0f%%", $0) }
                .font(DesignTokens.Typo.hero)
                .foregroundColor(severity.accent ?? .primary)
            Sparkline(values: healthStore.cpuHistory, maxValue: 100, color: severity.accent ?? .primary, animation: Motion.reduceMotionEnabled ? nil : .eulTween)
                .frame(height: 22)
                .padding(.top, 2)
            Text(severity != .normal ? healthStore.verdictText : String(format: "panel.cores".localized(), cpuStore.logicalCores))
                .font(DesignTokens.Typo.sub)
                .foregroundColor(secondary)
                .padding(.top, 2)
            if cpuIsExpanded {
                tileDivider()
                CoreGrid(usages: cpuStore.coreUsages, labels: cpuStore.coreLabels, accent: severity.accent)
                    .padding(.top, 8)
                Text("\("panel.load".localized()) \(cpuStore.loadAverage1MinString) · \(cpuStore.loadAverage5MinString) · \(cpuStore.loadAverage15MinString)\(cpuStore.upTimeString.map { "  ·  \(String(format: "panel.up".localized(), $0))" } ?? "")")
                    .font(DesignTokens.Typo.sub)
                    .foregroundColor(secondary)
                    .padding(.top, 8)
            }
        }
        return expandableTile("component.cpu".localized(), $cpuExpanded, tile)
    }

    private func memoryTile() -> some View {
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
        let severity = tileSeverity(.Memory)
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
            if memoryExpanded {
                tileDivider()
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
        return expandableTile("component.memory".localized(), $memoryExpanded, tile)
    }

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

    private func networkTile() -> some View {
        // NetworkPort.description handles the optional port name ("Wi-Fi (en0)")
        let aux = networkStore.currentActivePort.map { $0.description }
        let historyMax = max(healthStore.networkHistory.max() ?? 1, 1)
        let tile = PanelTile(label: "component.network".localized().uppercased(), aux: aux) {
            HStack(spacing: 2) {
                Text("↓").foregroundColor(secondary).font(.system(size: 11))
                rateText(networkStore.inSpeedInByte)
            }
            HStack(spacing: 2) {
                Text("↑").foregroundColor(secondary).font(.system(size: 11))
                rateText(networkStore.outSpeedInByte)
            }
            Sparkline(values: healthStore.networkHistory, maxValue: historyMax, animation: Motion.reduceMotionEnabled ? nil : .eulTween)
                .frame(height: 22)
                .padding(.top, 2)
            if networkExpanded {
                tileDivider()
                PanelDetailGrid(rows: [
                    ("panel.network.interface".localized(), aux ?? "network.no_activity".localized()),
                    ("network.total".localized(), ByteUnit(Double(networkStore.networkUsage.inBytes + networkStore.networkUsage.outBytes), kilo: 1000).readable),
                    ("panel.network.received".localized(), ByteUnit(Double(networkStore.networkUsage.inBytes), kilo: 1000).readable),
                    ("panel.network.sent".localized(), ByteUnit(Double(networkStore.networkUsage.outBytes), kilo: 1000).readable),
                ])
                .padding(.top, 8)
            }
        }
        return expandableTile("component.network".localized(), $networkExpanded, tile)
    }

    private func gpuTile() -> some View {
        let gpu = gpuStore.gpus.first
        var sub = gpu?.model ?? "component.gpu".localized()
        if let cores = gpu?.cores {
            sub += " · " + String(format: "panel.cores".localized(), cores)
        }
        let tile = PanelTile(
            label: "component.gpu".localized().uppercased(),
            aux: gpuStore.temperatureAverage?.temperatureString
        ) {
            RollingNumber(gpuStore.usageAverage) { String(format: "%.0f%%", $0) }
                .font(DesignTokens.Typo.hero)
            Spacer(minLength: 0)
            Text(sub)
                .font(DesignTokens.Typo.sub)
                .foregroundColor(secondary)
                .lineLimit(1)
            if gpuExpanded {
                let statistic = gpuStore.gpuStatistics.first
                tileDivider()
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
        return expandableTile("component.gpu".localized(), $gpuExpanded, tile)
    }

    private func diskTile() -> some View {
        let usedFraction: Double
        if let ceiling = diskStore.ceilingBytes, let free = diskStore.freeBytes, ceiling > 0 {
            usedFraction = Double(ceiling - free) / Double(ceiling)
        } else {
            usedFraction = 0
        }
        let severity = tileSeverity(.Disk)
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
            if !diskExpanded, isAllDisks, let disks = diskStore.list?.disks {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(disks) { disk in
                        Text(disk.name)
                            .font(.system(size: 10))
                            .lineLimit(1)
                    }
                }
                .padding(.top, 4)
            }
            if diskExpanded {
                tileDivider()
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
        return expandableTile("component.disk".localized(), $diskExpanded, tile)
    }

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

    /// Readings always; the control surface lives in the expanded state —
    /// intervention happens next to the temperatures that justify it (§2.7).
    /// On macOS < 13 there is nothing to expand: plain readings, no tap
    /// affordance, no teaser (absent, never gray).
    private func fansTile() -> AnyView {
        let controllable = fanControl.status != .unsupportedOS
        let expanded = fansExpanded && controllable
        // an unreachable helper means the controls would silently no-op —
        // the tile carries the cue so the repair affordance gets found
        let severity: HealthLevel = fanControl.status == .enabled && fanControl.helperUnreachable ? .elevated : .normal
        let tile = PanelTile(label: "component.fan".localized().uppercased(), aux: fanModeText, severity: severity) {
            if !expanded {
                ForEach(fanStore.fans) { fan in
                    HStack(spacing: 4) {
                        Text("\(fan.id + 1)")
                            .font(.system(size: 11))
                            .foregroundColor(secondary)
                        RollingNumber(fan.currentSpeed.map(Double.init)) { "\(Int($0)) rpm" }
                            .font(DesignTokens.Typo.mid)
                    }
                }
                Spacer(minLength: 0)
                Text(fanControl.status == .enabled && fanControl.overrideActive
                    ? "fan.control.override".localized()
                    : "panel.fans.system_managed".localized())
                    .font(DesignTokens.Typo.sub)
                    .foregroundColor(secondary)
            } else {
                if fanControl.status != .enabled {
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
                tileDivider()
                FanControlSurface()
                    .padding(.top, 2)
            }
        }
        guard controllable else {
            return AnyView(tile)
        }
        return AnyView(
            tile
                .contentShape(Rectangle())
                .onTapGesture {
                    fansExpanded.toggle()
                }
                .pointingHandCursor()
                .a11yExpandButton(label: "component.fan".localized())
        )
    }

    /// the one display-only cue: charge is monotonic on battery power, so a
    /// plain threshold can't flap like a raw usage sample would. Plugged in,
    /// a low percentage is a non-event — no color.
    private var batterySeverity: HealthLevel {
        guard !batteryStore.acPowered else {
            return .normal
        }
        if batteryStore.charge <= 0.1 {
            return .critical
        }
        if batteryStore.charge <= 0.2 {
            return .elevated
        }
        return .normal
    }

    private func batteryTile() -> some View {
        let severity = batterySeverity
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
            if batteryExpanded {
                tileDivider()
                PanelDetailGrid(rows: [
                    ("battery.max_capacity".localized(), batteryStore.maxCapacityText),
                    ("battery.design_capacity".localized(), batteryStore.designCapacityText),
                    ("battery.condition".localized(), batteryStore.io.condition.description),
                    ("battery.power_source".localized(), batteryStore.io.powerSource.description),
                ])
                .padding(.top, 8)
            }
        }
        return expandableTile("component.battery".localized(), $batteryExpanded, tile)
    }

    private func bluetoothDeviceDescription(_ device: BluetoothDevice) -> String {
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

    private func bluetoothTile(devices: [BluetoothDevice]) -> some View {
        PanelTile(
            label: "component.bluetooth".localized().uppercased(),
            aux: "\(devices.count)"
        ) {
            ForEach(devices.prefix(2), id: \.address) { device in
                VStack(alignment: .leading, spacing: 0) {
                    Text(device.name)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                    Text(bluetoothDeviceDescription(device))
                        .font(DesignTokens.Typo.sub)
                        .foregroundColor(secondary)
                }
            }
            Spacer(minLength: 0)
        }
    }

    /// Flows the tiles in their fixed order: a half-width tile waits for a
    /// partner, while an expanded tile closes the current row and takes a full
    /// row for itself. Expansion therefore happens in place — the sections keep
    /// their order and everything below simply moves down, instead of every
    /// expanded tile jumping to the top of the grid.
    private func tileRows(_ entries: [(view: AnyView, isFullWidth: Bool)]) -> [AnyView] {
        var rows: [AnyView] = []
        var pending: [AnyView] = []

        func flush() {
            guard !pending.isEmpty else {
                return
            }
            let leading = pending[0]
            let trailing = pending.count > 1 ? pending[1] : nil
            rows.append(AnyView(
                HStack(alignment: .top, spacing: DesignTokens.Panel.spacing) {
                    leading
                    if let trailing = trailing {
                        trailing
                    } else {
                        Color.clear.frame(maxWidth: .infinity)
                    }
                }
            ))
            pending.removeAll()
        }

        for entry in entries {
            if entry.isFullWidth {
                flush()
                rows.append(entry.view)
            } else {
                pending.append(entry.view)
                if pending.count == 2 {
                    flush()
                }
            }
        }
        flush()
        return rows
    }

    /// right-click → hide; hiding is point-of-use, restore lives in
    /// Settings · General (design §4.7)
    private func hideable(_ kind: PanelTileKind, _ view: some View) -> AnyView {
        AnyView(view.contextMenu {
            Button(String(format: "panel.tile.hide".localized(), kind.localizedDescription)) {
                preferenceStore.hideTile(kind)
            }
        })
    }

    private var tileGrid: some View {
        // built in the fixed section order; the layout helper decides which
        // tiles share a row, so an expansion never reorders the sections
        var tiles: [(view: AnyView, isFullWidth: Bool)] = []
        let hidden = preferenceStore.isTileHidden

        if !hidden(.cpu) {
            tiles.append((hideable(.cpu, cpuTile()), cpuIsExpanded))
        }
        if !hidden(.memory) {
            tiles.append((hideable(.memory, memoryTile()), memoryExpanded))
        }
        if !hidden(.network) {
            tiles.append((hideable(.network, networkTile()), networkExpanded))
        }
        if !hidden(.gpu) {
            tiles.append((hideable(.gpu, gpuTile()), gpuExpanded))
        }
        if !hidden(.disk) {
            tiles.append((hideable(.disk, diskTile()), diskExpanded))
        }
        if fanStore.fans.count > 0, !hidden(.fans) {
            tiles.append((hideable(.fans, fansTile()), fansExpanded && fanControl.status != .unsupportedOS))
        }
        if batteryStore.isValid, !hidden(.battery) {
            tiles.append((hideable(.battery, batteryTile()), batteryExpanded))
        }
        let btDevices = bluetoothStore.devices.filter { $0.hasBattery }
        if btDevices.count > 0, !hidden(.bluetooth) {
            tiles.append((hideable(.bluetooth, bluetoothTile(devices: btDevices)), false))
        }

        let rows = tileRows(tiles)
        return VStack(spacing: DesignTokens.Panel.spacing) {
            ForEach(0..<rows.count, id: \.self) { index in
                rows[index]
            }
        }
    }

    // MARK: processes

    private var lensPicker: some View {
        HStack(spacing: 2) {
            ForEach(UIStore.ProcLens.allCases) { lens in
                Button(action: {
                    uiStore.panelLens = lens
                }) {
                    Text(lens.localizedDescription)
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 3)
                        .background(uiStore.panelLens == lens ? Color.primary.opacity(0.15) : Color.clear)
                        .cornerRadius(5)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PlainButtonStyle())
                .pointingHandCursor()
            }
        }
        .padding(2)
        .background(Color.primary.opacity(0.08))
        .cornerRadius(7)
    }

    private var processRows: [AnyView] {
        switch uiStore.panelLens {
        case .cpu:
            return topStore.cpuTopProcesses.prefix(6).map {
                AnyView(PanelProcessRow(icon: $0.runningApp?.icon, name: $0.displayName, value: String(format: "%.1f%%", $0.value), pid: $0.pid, path: $0.processPath))
            }
        case .memory:
            return topStore.ramTopProcesses.prefix(6).map {
                AnyView(PanelProcessRow(icon: $0.runningApp?.icon, name: $0.displayName, value: ByteUnit(megaBytes: $0.usageAmount).readable, pid: $0.pid, path: $0.processPath))
            }
        case .network:
            return networkTopStore.processes.prefix(6).map {
                AnyView(PanelProcessRow(icon: $0.runningApp?.icon, name: $0.displayName, value: "↓ " + ByteUnit($0.value.inSpeedInByte).readableRate(inBits: preferenceStore.networkRateInBits), pid: $0.pid, path: $0.processPath))
            }
        }
    }

    private var processSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("panel.top_processes".localized().uppercased())
                    .font(DesignTokens.Typo.tileLabel)
                    .tracking(0.6)
                    .foregroundColor(secondary)
                Spacer()
                lensPicker
            }
            let rows = processRows
            if rows.isEmpty {
                Text("panel.collecting".localized())
                    .font(DesignTokens.Typo.sub)
                    .foregroundColor(secondary)
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 0) {
                    ForEach(0..<rows.count, id: \.self) { index in
                        if index > 0 {
                            Rectangle()
                                .fill(Color.primary.opacity(0.09))
                                .frame(height: 1)
                        }
                        rows[index]
                    }
                }
            }
        }
        .padding(EdgeInsets(top: 9, leading: 12, bottom: 5, trailing: 12))
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.Panel.tileRadius)
                .fill(Color.primary.opacity(0.06))
        )
        .padding(.top, 10)
    }

    // MARK: footer

    private var footer: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Color.primary.opacity(0.09))
                .frame(height: 1)
                .padding(.top, 10)
            HStack {
                Text(String(format: "panel.updated_every".localized(), "\(preferenceStore.smcRefreshRate) s"))
                Spacer()
                Text(String(format: "panel.self_usage".localized(), selfUsage.percentString))
            }
            .font(DesignTokens.Typo.sub)
            .foregroundColor(secondary)
            .padding(EdgeInsets(top: 8, leading: 4, bottom: 0, trailing: 4))
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            runawayCard
            tileGrid
            processSection
            footer
        }
        .padding(DesignTokens.Panel.padding)
        .frame(width: DesignTokens.Panel.width)
        .fixedSize()
        .overlay(FanCeremonyOverlay())
        .background(GeometryReader { self.reportSize($0) })
        .onPreferenceChange(SizePreferenceKey.self, perform: { value in
            if let size = value.first {
                onSizeChange?(size)
            }
        })
        .onReceive(NotificationCenter.default.publisher(for: .StoreShouldRefresh)) { _ in
            selfUsage.sample()
        }
        .onReceive(uiStore.$menuOpened) { opened in
            if opened {
                bluetoothStore.fetchAsync()
            }
        }
        .id(preferenceStore.language)
        .preferredColorScheme()
    }
}
