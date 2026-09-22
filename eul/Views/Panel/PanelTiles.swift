//
//  PanelTiles.swift
//  eul
//
//  Created by Gao Sun on 2026/6/10.
//  Copyright © 2026 Gao Sun. All rights reserved.
//

import SwiftUI

/// Panel tile container (design §7 Tile): label, optional aux figure, body
/// content; severity carries the surface's only color (§5.2) — amber for
/// elevated, red for critical. Tiles for absent hardware are absent, never
/// empty (§2.6).
struct PanelTile<Content: View>: View {
    var label: String
    var aux: String?
    var severity: HealthLevel = .normal
    /// One uniform tile height for the whole grid. Tiles differ in content
    /// (CPU carries a sparkline, memory a bar, battery only figures), and a
    /// per-tile min height let each settle at its own natural height — which
    /// read as mismatched boxes inside a row and squeezed the shorter tile's
    /// second line away. Sized to the tallest compact tile so every compact
    /// tile lands on the same height; expanded tiles move to full width.
    var minHeight: CGFloat? = 116
    @ViewBuilder var content: () -> Content

    var body: some View {
        let accent = severity.accent
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(label)
                    .font(DesignTokens.Typo.tileLabel)
                    .tracking(0.6)
                    .foregroundColor(.primary.opacity(0.55))
                Spacer()
                if let aux = aux {
                    CrossfadeText(aux)
                        .font(DesignTokens.Typo.sub)
                        .foregroundColor(accent ?? .primary.opacity(0.55))
                }
            }
            content()
        }
        .padding(EdgeInsets(top: 10, leading: 12, bottom: 9, trailing: 12))
        .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.Panel.tileRadius)
                .fill(Color.primary.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Panel.tileRadius)
                .stroke(accent?.opacity(0.7) ?? Color.clear, lineWidth: 1)
        )
    }
}

/// One labeled reading inside an expanded tile. Every expanded tile reuses
/// this so the detail layers share a single type size and baseline (§7).
struct PanelDetailRow: View {
    var label: String
    var value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(label)
                .font(.system(size: 10.5))
                .foregroundColor(.primary.opacity(0.55))
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(value)
                .font(Font.system(size: 10.5, weight: .medium).monospacedDigit())
                .lineLimit(1)
        }
    }
}

/// Two readings per line, so an expanded tile gains depth without doubling
/// the panel's height.
struct PanelDetailGrid: View {
    var rows: [(label: String, value: String)]

    var body: some View {
        VStack(spacing: 5) {
            ForEach(0..<(rows.count + 1) / 2, id: \.self) { index in
                HStack(spacing: 14) {
                    PanelDetailRow(label: rows[index * 2].label, value: rows[index * 2].value)
                    if index * 2 + 1 < rows.count {
                        PanelDetailRow(label: rows[index * 2 + 1].label, value: rows[index * 2 + 1].value)
                    } else {
                        Color.clear.frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }
}

/// Stacked horizontal bar; segments differentiated by opacity steps, never
/// hue — legible in both modes and to all color vision types (design §5.2)
struct SegmentBar: View {
    /// (fraction of full width, opacity)
    var segments: [(fraction: Double, opacity: Double)]

    /// the segment widths tween to their new fractions (§5.5, revised);
    /// opacities are static so only the geometry animates
    @State private var displayed: [Double] = []

    private func fraction(_ index: Int) -> Double {
        let value = displayed.indices.contains(index) ? displayed[index] : segments[index].fraction
        return min(max(value, 0), 1)
    }

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                ForEach(0..<segments.count, id: \.self) { index in
                    Rectangle()
                        .fill(Color.primary.opacity(segments[index].opacity))
                        .frame(width: max(0, geometry.size.width * CGFloat(fraction(index))))
                }
                Spacer(minLength: 0)
            }
        }
        .frame(height: 5)
        .background(Color.primary.opacity(0.12))
        .clipShape(Capsule())
        .padding(.top, 4)
        .onAppear { displayed = segments.map { $0.fraction } }
        .onChange(of: segments.map { $0.fraction }) { newValue in
            if Motion.reduceMotionEnabled {
                displayed = newValue
            } else {
                withAnimation(.eulTween) { displayed = newValue }
            }
        }
    }
}

/// Per-core micro-columns grouped and labeled E / P (design §7 CoreGrid)
struct CoreGrid: View {
    var usages: [Double]
    var labels: [String]
    var accent: Color?

    /// per-core column heights tween to their new usage (§5.5, revised)
    @State private var displayed: [Double] = []

    private struct Cluster {
        let label: String
        /// global core index → so the tweened height can be read by index
        let coreIndices: [Int]
    }

    private var clusters: [Cluster] {
        var groups: [(label: String, indices: [Int])] = []
        for index in usages.indices {
            let prefix = String(labels[safe: index]?.prefix(1) ?? "C")
            if let last = groups.last, last.label == prefix {
                groups[groups.count - 1].indices.append(index)
            } else {
                groups.append((prefix, [index]))
            }
        }
        return groups.map { Cluster(label: $0.label, coreIndices: $0.indices) }
    }

    private func usage(_ index: Int) -> Double {
        let value = displayed.indices.contains(index) ? displayed[index] : (usages[safe: index] ?? 0)
        return min(max(value / 100, 0), 1)
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 14) {
            ForEach(0..<clusters.count, id: \.self) { clusterIndex in
                HStack(alignment: .bottom, spacing: 4) {
                    Text(clusters[clusterIndex].label)
                        .font(.system(size: 9, weight: .semibold))
                        .tracking(0.5)
                        .foregroundColor(.primary.opacity(0.35))
                    ForEach(clusters[clusterIndex].coreIndices, id: \.self) { coreIndex in
                        ZStack(alignment: .bottom) {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color.primary.opacity(0.12))
                            RoundedRectangle(cornerRadius: 2)
                                .fill(accent ?? Color.primary.opacity(0.85))
                                .frame(height: 30 * CGFloat(usage(coreIndex)))
                        }
                        .frame(width: 9, height: 30)
                    }
                }
            }
        }
        .onAppear { displayed = usages }
        .onChange(of: usages) { newValue in
            if Motion.reduceMotionEnabled {
                displayed = newValue
            } else {
                withAnimation(.eulTween) { displayed = newValue }
            }
        }
    }
}

/// Process row (design §7 ProcessRow): app icon, name, tabular value
struct PanelProcessRow: View {
    var icon: NSImage?
    var name: String
    var value: String
    var pid: Int
    var path: String
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 9) {
                if let icon = icon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 19, height: 19)
                        .cornerRadius(5)
                } else {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.primary.opacity(0.25))
                        .frame(width: 19, height: 19)
                        .overlay(
                            Text(String(name.prefix(1)).uppercased())
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(.primary.opacity(0.8))
                        )
                }
                Text(name)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer()
                CrossfadeText(value)
                    .font(Font.system(size: 12, weight: .semibold).monospacedDigit())
            }
            if expanded {
                Text("PID \(pid) · \(path)")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.eulTween) {
                expanded.toggle()
            }
        }
        .help("PID \(pid)\n\(path)")
    }
}
