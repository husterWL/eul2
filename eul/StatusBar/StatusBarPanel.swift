//
//  StatusBarPanel.swift
//  eul
//
//  Created by Gao Sun on 2026/6/10.
//  Copyright © 2026 Gao Sun. All rights reserved.
//

import AppKit
import Combine
import SwiftUI

/// The investigation panel host (design §2.6): a borderless, nonactivating
/// NSPanel anchored under the anchor item — Control-Center behavior without
/// activating the app or stealing the frontmost app's menu bar. NSPopover is
/// unusable here: its transient dismissal is broken for inactive LSUIElement
/// apps on macOS 11–13 and the arrow cannot be removed.
final class StatusBarPanel: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: DesignTokens.Panel.width, height: 480),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace, .ignoresCycle]
        // NSPanel defaults to hiding on deactivate — an LSUIElement app is
        // rarely "active", so the panel would never show
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        animationBehavior = .utilityWindow
        isReleasedWhenClosed = false
    }

    /// borderless windows refuse key by default; without key the panel's
    /// controls and Esc handling don't work
    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        false
    }

    /// Esc — one of the two dismissal gestures the design names (§2.6)
    override func cancelOperation(_: Any?) {
        PanelManager.shared.close()
    }
}

/// Owns the panel lifecycle: positioning, click-away dismissal, and the
/// open-only collector contract — while the panel is closed the expensive
/// collectors (top/nettop) cost nothing (§2.6).
@MainActor
final class PanelManager: NSObject {
    static let shared = PanelManager()

    private var panel: StatusBarPanel?
    private var hostingView: NSHostingView<AnyView>?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var contentHeight: CGFloat = 480
    private var resizeScheduled = false
    private var lastCloseAt = Date.distantPast
    private var pendingAppearance: NSAppearance?
    private(set) var isOpen = false

    func setAppearance(_ appearance: NSAppearance?) {
        pendingAppearance = appearance
        panel?.appearance = appearance
    }

    func toggle() {
        // a click that just dismissed the panel via a monitor/resign-key may
        // also fire a status-item action — don't treat it as a reopen
        if !isOpen, Date().timeIntervalSince(lastCloseAt) < 0.25 {
            return
        }
        isOpen ? close() : open()
    }

    func open(centered: Bool = false) {
        let panel = ensurePanel()
        position(panel, centered: centered)
        panel.orderFrontRegardless()
        panel.makeKey()
        StatusBarManager.shared.entryButton?.highlight(true)
        if !isOpen {
            // mount the content tree only on the closed→open transition —
            // ensurePanel already built it for the first open, and re-assigning
            // rootView on every open used to build the whole PanelView twice
            hostingView?.rootView = makeRootView()
            isOpen = true
            // the collector contract: panel open = menu open (TopStore,
            // NetworkTopStore, GPU/Disk refresh gating)
            SharedStore.ui.menuOpened = true
            // wake only the stores that were skipping work while closed — a
            // broadcast .StoreShouldRefresh would force the delta-based
            // stores (CPU) into a near-zero-interval garbage sample
            SharedStore.gpu.refresh()
            SharedStore.disk.refresh()
            installMonitors()
        }
    }

    /// Recovery path (§2.5): relaunch-while-running and the global hotkey
    /// open the panel centered when the bar item is unreachable
    func openCentered() {
        open(centered: true)
    }

    func close() {
        guard isOpen else {
            return
        }
        isOpen = false
        lastCloseAt = Date()
        removeMonitors()
        panel?.orderOut(nil)
        hostingView?.rootView = AnyView(EmptyView())
        SharedStore.ui.menuOpened = false
        StatusBarManager.shared.anchor.item.button?.highlight(false)
        StatusBarManager.shared.strip.item.button?.highlight(false)
    }

    private func makeRootView() -> AnyView {
        AnyView(
            PanelView(onSizeChange: { [weak self] size in
                self?.handleContentSize(size)
            })
            .withGlobalEnvironmentObjects()
        )
    }

    private func ensurePanel() -> StatusBarPanel {
        if let panel = panel {
            return panel
        }

        let panel = StatusBarPanel()
        panel.appearance = pendingAppearance

        let visual = NSVisualEffectView()
        visual.material = .popover
        visual.blendingMode = .behindWindow
        visual.state = .active
        visual.wantsLayer = true
        visual.layer?.cornerRadius = DesignTokens.Panel.cornerRadius
        visual.layer?.masksToBounds = true
        panel.contentView = visual

        // mounted empty: open() assigns the real tree on the closed→open
        // transition, so the first open builds PanelView exactly once
        let hosting = NSHostingView(rootView: AnyView(EmptyView()))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        visual.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: visual.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: visual.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: visual.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: visual.bottomAnchor),
        ])
        hostingView = hosting

        // existing close requests (open-preferences, process actions) reuse
        // the menu-era notification; queue: .main delivers on the main thread,
        // so assumeIsolated is the truthful bridge into the MainActor class
        observers.append(NotificationCenter.default.addObserver(
            forName: .StatusBarMenuShouldClose, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.close()
            }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.close()
            }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.close()
            }
        })
        // catches Cmd-Tab and clicks into other windows of our own app
        observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.close()
            }
        })

        self.panel = panel
        return panel
    }

    private func handleContentSize(_ size: CGSize) {
        // ignore sub-pixel jitter, and coalesce to one resize per runloop
        // turn — tile expand animations used to report intermediate heights
        // every frame, resizing the window every frame with them
        guard abs(size.height - contentHeight) >= 0.5 else {
            return
        }
        contentHeight = size.height
        guard !resizeScheduled else {
            return
        }
        resizeScheduled = true
        DispatchQueue.main.async { [self] in
            resizeScheduled = false
            guard let panel = panel, isOpen else {
                return
            }
            var frame = panel.frame
            let top = frame.maxY
            frame.size.height = contentHeight
            frame.origin.y = top - contentHeight
            panel.setFrame(frame, display: true)
        }
    }

    private func position(_ panel: StatusBarPanel, centered: Bool) {
        let width = DesignTokens.Panel.width
        let height = contentHeight

        if
            !centered,
            let window = StatusBarManager.shared.entryWindow,
            let screen = window.screen
        {
            // the button window's frame is in global screen coordinates and
            // spans the menu bar height; clamp into the clicked screen
            let barFrame = window.frame
            let visible = screen.visibleFrame
            let x = min(max(barFrame.midX - width / 2, visible.minX + 8), visible.maxX - width - 8)
            // never let the panel's bottom edge run off-screen on short
            // displays (the content itself is capped + scrollable too)
            let y = max(barFrame.minY - height - 5, visible.minY + 8)
            panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
        } else if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            panel.setFrame(
                NSRect(x: visible.midX - width / 2, y: visible.midY - height / 2, width: width, height: height),
                display: true
            )
        }
    }

    private func installMonitors() {
        // global monitor sees clicks delivered to OTHER apps; mouse-only
        // monitoring needs no accessibility permission
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.close()
        }
        // local monitor covers clicks in our own windows; bar-item clicks are
        // excluded — their own actions decide (toggle)
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            if let self = self, let panel = self.panel {
                let barWindows = [
                    StatusBarManager.shared.anchor.item.button?.window,
                    StatusBarManager.shared.strip.item.button?.window,
                ]
                if event.window !== panel, !barWindows.contains(where: { $0 === event.window }) {
                    self.close()
                }
            }
            return event
        }
    }

    private func removeMonitors() {
        if let monitor = globalMonitor {
            NSEvent.removeMonitor(monitor)
            globalMonitor = nil
        }
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }
    }
}
