//
//  PanelSections.swift
//  eul
//
//  The panel's non-tile sections, each an independent view declaring only
//  the stores it reads — extracted from PanelView's single body so a store
//  tick re-evaluates just the section that displays it.
//

import AppKit
import Localize_Swift
import SharedLibrary
import SwiftUI

private var secondary: Color {
    DesignTokens.Surfaces.secondaryText
}

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

// MARK: - header

struct PanelHeaderView: View {
    @EnvironmentObject var healthStore: HealthStore
    @EnvironmentObject var cpuStore: CpuStore
    @EnvironmentObject var preferenceStore: PreferenceStore
    @EnvironmentObject var fanControl: FanControlStore

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
                headerIcon("sparkles", label: "clean_mode.action".localized(), tint: secondary, background: DesignTokens.Surfaces.controlBackground) {
                    AppDelegate.enterCleanMode()
                }
                headerIcon("gearshape", label: "menu.preferences".localized(), tint: secondary, background: DesignTokens.Surfaces.controlBackground) {
                    AppDelegate.openPreferences()
                }
                headerIcon("power", label: "menu.quit".localized(), tint: DesignTokens.Health.critical, background: DesignTokens.Health.critical.opacity(0.12)) {
                    AppDelegate.quit()
                }
            }
            .fixedSize()
        }
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

    var body: some View {
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
}

// MARK: - runaway card

struct PanelRunawayCard: View {
    @EnvironmentObject var healthStore: HealthStore

    var body: some View {
        if healthStore.activeSignal == .runaway, let pid = healthStore.runawayCulpritPid {
            let duration = Int(healthStore.runawayDuration)
            let detail = "\(healthStore.runawayCulprit ?? "?") · PID \(pid) · \(duration / 60)m \(duration % 60)s"
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
        }
    }
}

// MARK: - processes

struct PanelProcessSection: View {
    @EnvironmentObject var uiStore: UIStore
    @EnvironmentObject var topStore: TopStore
    @EnvironmentObject var networkTopStore: NetworkTopStore
    @EnvironmentObject var preferenceStore: PreferenceStore

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
                        .background(uiStore.panelLens == lens ? DesignTokens.Surfaces.selection : Color.clear)
                        .cornerRadius(5)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PlainButtonStyle())
                .pointingHandCursor()
            }
        }
        .padding(2)
        .background(DesignTokens.Surfaces.controlBackground)
        .cornerRadius(7)
    }

    private var hasProcesses: Bool {
        switch uiStore.panelLens {
        case .cpu:
            return !topStore.cpuTopProcesses.isEmpty
        case .memory:
            return !topStore.ramTopProcesses.isEmpty
        case .network:
            return !networkTopStore.processes.isEmpty
        }
    }

    private var processDivider: some View {
        Rectangle()
            .fill(DesignTokens.Surfaces.divider)
            .frame(height: 1)
    }

    /// Rows are identified by PID, not by array index: the lists re-sort every
    /// tick, and index identity kept a row's expanded PID/path detail attached
    /// to the POSITION — one tick later it described a different process.
    @ViewBuilder private var processList: some View {
        switch uiStore.panelLens {
        case .cpu:
            let procs = Array(topStore.cpuTopProcesses.prefix(TopStore.rowCount))
            ForEach(Array(procs.enumerated()), id: \.element.pid) { index, proc in
                if index > 0 {
                    processDivider
                }
                PanelProcessRow(icon: proc.runningApp?.icon, name: proc.displayName, value: String(format: "%.1f%%", proc.value), pid: proc.pid, path: proc.processPath)
            }
        case .memory:
            let procs = Array(topStore.ramTopProcesses.prefix(TopStore.rowCount))
            ForEach(Array(procs.enumerated()), id: \.element.pid) { index, proc in
                if index > 0 {
                    processDivider
                }
                PanelProcessRow(icon: proc.runningApp?.icon, name: proc.displayName, value: ByteUnit(megaBytes: proc.usageAmount).readable, pid: proc.pid, path: proc.processPath)
            }
        case .network:
            let procs = Array(networkTopStore.processes.prefix(TopStore.rowCount))
            ForEach(Array(procs.enumerated()), id: \.element.pid) { index, proc in
                if index > 0 {
                    processDivider
                }
                PanelProcessRow(icon: proc.runningApp?.icon, name: proc.displayName, value: "↓ " + ByteUnit(proc.value.inSpeedInByte).readableRate(inBits: preferenceStore.networkRateInBits), pid: proc.pid, path: proc.processPath)
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("panel.top_processes".localized().uppercased())
                    .font(DesignTokens.Typo.tileLabel)
                    .tracking(0.6)
                    .foregroundColor(secondary)
                Spacer()
                lensPicker
            }
            if !hasProcesses {
                Text("panel.collecting".localized())
                    .font(DesignTokens.Typo.sub)
                    .foregroundColor(secondary)
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 0) {
                    processList
                }
            }
        }
        .padding(EdgeInsets(top: 9, leading: 12, bottom: 5, trailing: 12))
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.Panel.tileRadius)
                .fill(DesignTokens.Surfaces.tileBackground)
        )
        .padding(.top, 10)
    }
}

// MARK: - footer

struct PanelFooterView: View {
    @EnvironmentObject var preferenceStore: PreferenceStore
    @StateObject private var selfUsage = SelfUsageSampler()

    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(DesignTokens.Surfaces.divider)
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
        .onReceive(NotificationCenter.default.publisher(for: .StoreShouldRefresh)) { _ in
            selfUsage.sample()
        }
    }
}
