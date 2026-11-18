//
//  StatusBarItem.swift
//  eul
//
//  Created by Gao Sun on 2020/8/21.
//  Copyright © 2020 Gao Sun. All rights reserved.
//

import Cocoa
import Combine
import SwiftUI

extension Notification.Name {
    static let StatusBarMenuShouldClose = Notification.Name("StatusBarMenuShouldClose")
}

/// Shared plumbing for eul's two status items. Only ONE is ever visible —
/// the slots strip in normal operation, the eyes-only anchor at the
/// collapse floor — so eul always reads as a single entry point (user
/// feedback: two simultaneous icons were perceived as two apps / a bug).
@MainActor
class BaseStatusItem: NSObject {
    static let leadingPosition = Double.greatestFiniteMagnitude

    let item: NSStatusItem
    let autosaveNameString: String
    private let contextMenu = NSMenu()
    private var cleanModeMenuItem: NSMenuItem?

    /// AppKit deletes "NSStatusItem Preferred Position" when an item is
    /// hidden, so the user's dragged position is stashed across hide/show
    /// cycles (#40, #113)
    fileprivate var stashedPosition: Any?

    fileprivate var positionKey: String {
        "NSStatusItem Preferred Position \(autosaveNameString)"
    }

    /// True when the item exists but the system is not drawing it — hidden
    /// for lack of menu bar space (overflow/notch) while isVisible stays
    /// true. Uses occlusionState as the primary signal (like 1.6.3) because
    /// frame-based detection is unreliable due to window drift during macOS
    /// re-layouts. Only returns true when occlusionState explicitly reports
    /// not visible, preventing false-positive slot drops.
    var isOccluded: Bool {
        guard item.isVisible, let window = item.button?.window else {
            return false
        }
        // Use occlusionState as the primary signal — if the window reports
        // visible, trust it. Only report occluded when explicitly not visible.
        return !window.occlusionState.contains(.visible)
    }

    var isVisible: Bool {
        item.isVisible
    }

    /// Show/hide while preserving the autosaved position: capture it before
    /// hiding (AppKit removes it synchronously), restore it before showing
    func setVisible(_ visible: Bool) {
        if visible {
            if let stashedPosition = stashedPosition {
                UserDefaults.standard.set(stashedPosition, forKey: positionKey)
                self.stashedPosition = nil
            }
            item.isVisible = true
            didBecomeVisible()
        } else {
            if let current = UserDefaults.standard.object(forKey: positionKey) {
                stashedPosition = current
            }
            item.isVisible = false
        }
    }

    /// AppKit can recreate the button across isVisible off/on toggles, which
    /// leaves a hosting view attached to the OLD button (blank item). Every
    /// show path funnels through here so subclasses reattach immediately —
    /// previously the anchor stayed blank until the next health-level change
    /// and the strip until the next renderBar.
    func didBecomeVisible() {}

    /// Take over the other item's bar position so the strip↔anchor swap
    /// doesn't make the eyes jump across the menu bar; applied by the next
    /// setVisible(true)
    func adoptPosition(from other: BaseStatusItem) {
        let position = other.isVisible
            ? UserDefaults.standard.object(forKey: other.positionKey)
            : other.stashedPosition
        if let position = position {
            stashedPosition = position
        }
    }

    static func preferredPosition(for autosaveName: String) -> Double? {
        UserDefaults.standard.object(forKey: "NSStatusItem Preferred Position \(autosaveName)") as? Double
    }

    /// Left-click opens the panel; right/control-click shows the small
    /// Preferences/Quit menu. Identical on both items.
    @objc fileprivate func handleClick() {
        let event = NSApp.currentEvent
        let isContextClick = event?.type == .rightMouseUp
            || (event?.type == .leftMouseUp && event?.modifierFlags.contains(.control) == true)
        if isContextClick {
            // titles are snapshots — refresh in case the language changed
            contextMenu.items.first?.title = "menu.preferences".localized()
            cleanModeMenuItem?.title = "menu.clean_mode".localized()
            contextMenu.items.last?.title = "menu.quit".localized()
            // a permanently-assigned menu would own left-click too, so assign
            // it only for the duration of this click
            item.menu = contextMenu
            item.button?.performClick(nil)
            item.menu = nil
        } else {
            PanelManager.shared.toggle()
        }
    }

    @objc private func openPreferences() {
        AppDelegate.openPreferences()
    }

    @objc private func quit() {
        AppDelegate.quit()
    }

    @objc private func enterCleanMode() {
        AppDelegate.enterCleanMode()
    }

    fileprivate func setupButton() {
        let preferencesItem = NSMenuItem(title: "menu.preferences".localized(), action: #selector(openPreferences), keyEquivalent: ",")
        preferencesItem.target = self
        contextMenu.addItem(preferencesItem)
        let cleanModeItem = NSMenuItem(title: "menu.clean_mode".localized(), action: #selector(enterCleanMode), keyEquivalent: "")
        cleanModeItem.target = self
        contextMenu.addItem(cleanModeItem)
        cleanModeMenuItem = cleanModeItem
        contextMenu.addItem(NSMenuItem.separator())
        let quitItem = NSMenuItem(title: "menu.quit".localized(), action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        contextMenu.addItem(quitItem)

        item.button?.target = self
        item.button?.action = #selector(handleClick)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        // the buttons carry no title/image, so VoiceOver would announce a
        // nameless button; "eul" is the deliberately unlocalized product mark
        item.button?.setAccessibilityLabel("eul")
    }

    init(autosaveName: String, length: CGFloat) {
        autosaveNameString = autosaveName
        // seed the leftmost position ONLY on first run — writing it
        // unconditionally used to wipe the position AppKit autosaved from
        // the user's drag on every launch
        let key = "NSStatusItem Preferred Position \(autosaveName)"
        if UserDefaults.standard.object(forKey: key) == nil {
            UserDefaults.standard.set(Self.leadingPosition, forKey: key)
        }
        item = NSStatusBar.system.statusItem(withLength: length)
        super.init()
        item.autosaveName = autosaveName
    }
}

/// The collapse floor (design §2.2): an eyes-only item shown when the strip
/// has nothing to show or won't fit. Identity, health, and the entry point
/// in 28 pt — eul never disappears by its own choice.
class AnchorStatusItem: BaseStatusItem {
    static let autosaveName = "eul.anchor"
    static let itemLength: CGFloat = 28
    static let glyphWidth: CGFloat = 18

    private var hostingView: NSHostingView<AnyView>?
    private var healthCancellable: AnyCancellable?

    init() {
        super.init(autosaveName: Self.autosaveName, length: Self.itemLength)
        // visible during the manager's startup window so the bar is never
        // empty; the first renderBar() swaps to the strip when slots exist
        item.isVisible = true

        setupButton()
        render()
        healthCancellable = SharedStore.health.$level.sink { [weak self] level in
            DispatchQueue.main.async {
                self?.render(level: level)
            }
        }
    }

    override func didBecomeVisible() {
        render()
    }

    private func render(level: HealthLevel = SharedStore.health.level) {
        let root = AnyView(
            EyesGlyph(state: level.glyphState, width: Self.glyphWidth)
                .frame(width: Self.itemLength, height: AppDelegate.statusBarHeight)
                .allowsHitTesting(false)
        )
        if let view = hostingView {
            // reuse the mounted tree on health-level changes
            view.rootView = root
            // menu bar thickness can change (display plug/unplug, notch) —
            // keep the hosting frame in sync, not just at creation time
            view.setFrameSize(NSSize(width: Self.itemLength, height: AppDelegate.statusBarHeight))
            if view.superview !== item.button {
                // AppKit recreates the button across isVisible off/on toggles
                item.button?.subviews.forEach { $0.removeFromSuperview() }
                item.button?.addSubview(view)
            }
            return
        }
        let view = NSHostingView(rootView: root)
        view.setFrameSize(NSSize(width: Self.itemLength, height: AppDelegate.statusBarHeight))
        item.button?.subviews.forEach { $0.removeFromSuperview() }
        item.button?.addSubview(view)
        hostingView = view
    }
}

/// The primary item: the pinned slots as one unit, collapsing slot-by-slot
/// under width pressure before swapping to the eyes-only anchor floor.
/// Keeps the legacy "eul" autosaveName so existing users' saved position
/// survives the upgrade.
class StripStatusItem: BaseStatusItem {
    static let autosaveName = "eul"

    private var statusView: NSHostingView<AnyView>?
    private(set) var slotLimit = Int.max

    init() {
        super.init(autosaveName: Self.autosaveName, length: 0)
        setupButton()
        // start hidden (position-preserving) so an ungoverned full-width
        // strip never flashes at launch; the manager's first renderBar
        // decides visibility ~0.5 s later
        setVisible(false)
    }

    override func didBecomeVisible() {
        render(slotLimit: slotLimit)
    }

    private func onSizeChange(size: CGSize) {
        DispatchQueue.main.async { [self] in
            let width = size.width + 8
            // SwiftUI reports the size on EVERY re-render, not only on real
            // geometry changes. Re-assigning item.length / the hosting frame
            // unconditionally made AppKit invalidate and re-snapshot the
            // status item (full layout + text typesetting) on every store
            // tick — the dominant always-on CPU cost. Touch AppKit only when
            // the width actually moved.
            if abs(item.length - width) >= 0.5 {
                item.length = width
            }
            // height matters too: menu bar thickness changes on display
            // plug/unplug with the strip width unchanged
            if let view = statusView,
               abs(view.frame.width - width) >= 0.5
               || abs(view.frame.height - AppDelegate.statusBarHeight) >= 0.5
            {
                view.setFrameSize(NSSize(width: width, height: AppDelegate.statusBarHeight))
            }
        }
    }

    func render(slotLimit: Int) {
        let limitChanged = slotLimit != self.slotLimit
        self.slotLimit = slotLimit
        if let view = statusView {
            // unchanged limit + attached view = no-op: the live tree already
            // reflects store state via its environment objects. Recreating
            // it here would discard the mounted tree and flash a 0-width
            // item until the async size report lands.
            if limitChanged {
                view.rootView = AnyView(
                    StripView(onSizeChange: { [weak self] in self?.onSizeChange(size: $0) }, slotLimit: slotLimit)
                        .withGlobalEnvironmentObjects()
                )
            }
            if view.superview !== item.button {
                // AppKit recreates the button across isVisible off/on toggles (dropSlot recovery)
                item.button?.subviews.forEach { $0.removeFromSuperview() }
                item.button?.addSubview(view)
            }
            return
        }
        let view = NSHostingView(rootView: AnyView(
            StripView(onSizeChange: { [weak self] in self?.onSizeChange(size: $0) }, slotLimit: slotLimit)
                .withGlobalEnvironmentObjects()
        ))
        view.setFrameSize(NSSize(width: 0, height: AppDelegate.statusBarHeight))
        item.button?.subviews.forEach { $0.removeFromSuperview() }
        item.button?.addSubview(view)
        statusView = view
    }
}
