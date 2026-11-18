//
//  PanelView.swift
//  eul
//
//  Created by Gao Sun on 2026/6/10.
//  Copyright © 2026 Gao Sun. All rights reserved.
//

import AppKit
import SharedLibrary
import SwiftUI

/// The investigation panel (design §2.6): replaces the dropdown. Reads
/// top-down — verdict, tiles (the abnormal one carries the only color),
/// processes, footprint. Answers "why" in at most two interactions.
///
/// This view is a thin COMPOSITION layer: it owns only the expansion state,
/// the tile visibility gates, and the row-flow layout. Every section is an
/// independent view (PanelHeaderView, the tiles in PanelTileViews.swift,
/// PanelProcessSection, PanelFooterView) declaring only the stores it reads,
/// so a store tick re-evaluates just the section that displays it — the old
/// single body with 14 @EnvironmentObjects re-evaluated ALL of it on every
/// tick of ANY store.
struct PanelView: View, SizeChangeView {
    // gating subscriptions only — these change rarely (tile-hidden set,
    // hardware presence), not on every tick
    @EnvironmentObject var preferenceStore: PreferenceStore
    @EnvironmentObject var fanStore: FanStore
    @EnvironmentObject var batteryStore: BatteryStore
    @EnvironmentObject var bluetoothStore: BluetoothStore

    @State private var cpuExpanded = false
    @State private var fansExpanded = false
    @State private var memoryExpanded = false
    @State private var networkExpanded = false
    @State private var gpuExpanded = false
    @State private var diskExpanded = false
    @State private var batteryExpanded = false

    var onSizeChange: ((CGSize) -> Void)?

    /// Content height measured inside the scroll view; the panel shrinks to
    /// fit small content and caps at the screen's visible height otherwise.
    @State private var measuredContentHeight: CGFloat = 0

    private var maxPanelHeight: CGFloat {
        // visibleFrame already excludes the menu bar; keep a small margin so
        // the panel never touches the screen edge or the Dock
        (NSScreen.main?.visibleFrame.height ?? 900) - 40
    }

    // MARK: layout

    /// Flows the tiles in their fixed order: a half-width tile waits for a
    /// partner, while an expanded tile closes the current row and takes a full
    /// row for itself. Expansion therefore happens in place — the sections keep
    /// their order and everything below simply moves down, instead of every
    /// expanded tile jumping to the top of the grid.
    /// Rows carry the kind of their first tile as a STABLE identity — using
    /// the row index let @State inside a row (rolling values, segment bars)
    /// stick to the position and briefly show another tile's data when rows
    /// shifted.
    private func tileRows(_ entries: [(kind: PanelTileKind, view: AnyView, isFullWidth: Bool)]) -> [(id: PanelTileKind, view: AnyView)] {
        var rows: [(id: PanelTileKind, view: AnyView)] = []
        var pending: [(kind: PanelTileKind, view: AnyView)] = []

        func flush() {
            guard !pending.isEmpty else {
                return
            }
            let leading = pending[0]
            let trailing = pending.count > 1 ? pending[1] : nil
            rows.append((id: leading.kind, view: AnyView(
                HStack(alignment: .top, spacing: DesignTokens.Panel.spacing) {
                    leading.view
                    if let trailing = trailing {
                        trailing.view
                    } else {
                        Color.clear.frame(maxWidth: .infinity)
                    }
                }
            )))
            pending.removeAll()
        }

        for entry in entries {
            if entry.isFullWidth {
                flush()
                rows.append((id: entry.kind, view: entry.view))
            } else {
                pending.append((kind: entry.kind, view: entry.view))
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
        var tiles: [(kind: PanelTileKind, view: AnyView, isFullWidth: Bool)] = []
        let hidden = preferenceStore.isTileHidden

        if !hidden(.cpu) {
            let cpuIsExpanded = cpuExpanded || SharedStore.health.abnormalComponent == .CPU
            tiles.append((.cpu, hideable(.cpu, PanelCpuTile(expanded: $cpuExpanded)), cpuIsExpanded))
        }
        if !hidden(.memory) {
            tiles.append((.memory, hideable(.memory, PanelMemoryTile(expanded: $memoryExpanded)), memoryExpanded))
        }
        if !hidden(.network) {
            tiles.append((.network, hideable(.network, PanelNetworkTile(expanded: $networkExpanded)), networkExpanded))
        }
        if !hidden(.gpu) {
            tiles.append((.gpu, hideable(.gpu, PanelGpuTile(expanded: $gpuExpanded)), gpuExpanded))
        }
        if !hidden(.disk) {
            tiles.append((.disk, hideable(.disk, PanelDiskTile(expanded: $diskExpanded)), diskExpanded))
        }
        if fanStore.fans.count > 0, !hidden(.fans) {
            let fansControllable = SharedStore.fanControl.status != .unsupportedOS
            tiles.append((.fans, hideable(.fans, PanelFansTile(expanded: $fansExpanded)), fansExpanded && fansControllable))
        }
        if batteryStore.isValid, !hidden(.battery) {
            tiles.append((.battery, hideable(.battery, PanelBatteryTile(expanded: $batteryExpanded)), batteryExpanded))
        }
        let btDevices = bluetoothStore.devices.filter { $0.hasBattery }
        if btDevices.count > 0, !hidden(.bluetooth) {
            tiles.append((.bluetooth, hideable(.bluetooth, PanelBluetoothTile(devices: btDevices)), false))
        }

        let rows = tileRows(tiles)
        return VStack(spacing: DesignTokens.Panel.spacing) {
            ForEach(rows, id: \.id) { row in
                row.view
            }
        }
    }

    // MARK: body

    var body: some View {
        // Several tiles can be expanded at once; on short displays the total
        // content used to run off-screen with no way to reach the bottom.
        // The content is now capped and scrollable.
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 0) {
                PanelHeaderView()
                PanelRunawayCard()
                tileGrid
                PanelProcessSection()
                PanelFooterView()
            }
            .padding(DesignTokens.Panel.padding)
            .frame(width: DesignTokens.Panel.width)
            .background(GeometryReader { proxy in
                Color.clear.preference(key: PanelContentHeightKey.self, value: proxy.size.height)
            })
        }
        .frame(width: DesignTokens.Panel.width)
        .frame(height: measuredContentHeight > 0 ? min(measuredContentHeight, maxPanelHeight) : nil)
        .onPreferenceChange(PanelContentHeightKey.self) { height in
            if abs(height - measuredContentHeight) >= 0.5 {
                measuredContentHeight = height
            }
        }
        .overlay(FanCeremonyOverlay())
        .background(GeometryReader { self.reportSize($0) })
        .onPreferenceChange(SizePreferenceKey.self, perform: { value in
            if let size = value.first {
                onSizeChange?(size)
            }
        })
        .onReceive(SharedStore.ui.$menuOpened) { opened in
            if opened {
                bluetoothStore.fetchAsync()
            }
        }
        .id(preferenceStore.language)
        .preferredColorScheme()
    }
}

/// Separate from SizePreferenceKey so the inner content measurement and the
/// outer frame report don't mix in one preference stream.
private struct PanelContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
