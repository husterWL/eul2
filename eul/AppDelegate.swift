//
//  AppDelegate.swift
//  eul
//
//  Created by Gao Sun on 2020/6/21.
//  Copyright © 2020 Gao Sun. All rights reserved.
//

import Cocoa
import Combine
import Localize_Swift
import SharedLibrary
import SwiftUI
import UserNotifications

/// @main (not the deprecated NSApplicationMain attribute): the SDK extension
/// on NSApplicationDelegate provides the entry point under Swift 6
@main
@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var isSleeping = false
    // Invalidates pending asyncAfter chains: a brief sleep/wake used to leave
    // the old refresh chain alive next to the new one, multiplying the
    // effective refresh rate after every wake (#76, #18)
    private var refreshGeneration = 0
    private var updateCheckGeneration = 0
    private var updateMethodCancellable: AnyCancellable?
    private var appearanceCancellable: AnyCancellable?
    /// the Settings SwiftUI tree is mounted only while the window is visible
    /// (same pattern as PanelManager); a hidden tree would re-diff on every
    /// store tick around the clock
    private var settingsHostingView: NSHostingView<AnyView>?

    var window: NSWindow!
    /// plain storage — @ObservedObject has no effect outside SwiftUI Views;
    /// preference changes are subscribed explicitly via cancellables
    let preferenceStore = SharedStore.preference

    func applicationDidFinishLaunching(_: Notification) {
        // HIG (settings windows): titled, closable and miniaturizable, never
        // resizable/zoomable; the transparent titlebar keeps the rail design
        // while the title still draws
        window = NSWindow(
            contentRect: NSRect(origin: .zero, size: DesignTokens.Size.settingsWindow),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.center()
        window.setFrameAutosaveName("Eul Preferences")
        // the settings content is fixed-size; override a stale autosaved frame
        window.setContentSize(DesignTokens.Size.settingsWindow)
        // placeholder until openPreferences mounts ContentView; the fixed
        // frame keeps the non-resizable window's geometry stable
        let hosting = NSHostingView(rootView: AnyView(EmptyView().frame(width: DesignTokens.Size.settingsWindow.width, height: DesignTokens.Size.settingsWindow.height)))
        settingsHostingView = hosting
        window.contentView = hosting
        window.isReleasedWhenClosed = false
        window.title = "settings.title".localized()
        window.titlebarAppearsTransparent = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.delegate = self

        // comment out for not showing window at login. no proper solution currently, tracking:
        // https://github.com/sindresorhus/LaunchAtLogin/issues/33
        // window.makeKeyAndOrderFront(nil)
        // NSApp.activate(ignoringOtherApps: true)

        SmcControl.shared.subscribe()
        StatusBarManager.shared.checkVisibilityIfNeeded()
        GlobalHotKey.register()
        // clicking the "eul is hidden" notification must lead somewhere:
        // it opens the panel centered, same as relaunch and the hotkey.
        // Guarded like RecoveryNotifier — UN APIs throw for unbundled builds.
        if Bundle.main.bundleURL.pathExtension == "app" {
            UNUserNotificationCenter.current().delegate = self
        }
        wakeUp()

        let notificationCenter = NSWorkspace.shared.notificationCenter
        // explicit .main: sleep/wake handlers touch stores and runloop timers;
        // assumeIsolated bridges the @Sendable observer closure into the
        // MainActor class truthfully (queue: .main delivers on main)
        notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
            print("😪 going to sleep")
            MainActor.assumeIsolated {
                self.sleep()
            }
        }
        notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            print("🤩 woke up")
            MainActor.assumeIsolated {
                self.wakeUp()
            }
        }
        updateMethodCancellable = preferenceStore.$upgradeMethod.sink { _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.restartUpdateCheck()
                }
            }
        }

        // Disable in Catalina to avoid protential crash
        if #available(OSX 11, *) {
            appearanceCancellable = preferenceStore.$appearanceMode.sink { mode in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self.window.appearance = mode.nsAppearance
                        NSApp.appearance = mode.nsAppearance
                        PanelManager.shared.setAppearance(mode.nsAppearance)
                    }
                }
            }
        }
    }

    func applicationShouldTerminate(_: NSApplication) -> NSApplication.TerminateReply {
        print("🤚 should terminate")
        // best-effort; the helper's watchdog covers crashes and force-quits
        SharedStore.fanControl.revertAllOnQuit()
        // restore brightness + re-enable the keyboard if quit lands mid-clean
        // (the event tap also dies with the process, but this is the tidy path)
        SharedStore.cleanMode.forceExit()
        SmcControl.shared.close()
        return .terminateNow
    }

    /// Recovery flow (§2.5): launching eul while it is already running opens
    /// the panel as a centered window — the path back in when the menu bar
    /// is full and macOS hid even the anchor
    func applicationShouldHandleReopen(_: NSApplication, hasVisibleWindows _: Bool) -> Bool {
        PanelManager.shared.openCentered()
        return false
    }

    func wakeUp() {
        isSleeping = false
        refreshGeneration += 1
        // HID sensor services can go stale across sleep — re-enumerate so
        // temperatures don't stay missing until relaunch
        #if arch(arm64)
            AppleSiliconSensors.shared?.reattachAfterWake()
        #endif
        refreshSMCRepeatedly(generation: refreshGeneration)
        refreshNetworkRepeatedly(generation: refreshGeneration)
        restartUpdateCheck()
    }

    func restartUpdateCheck() {
        updateCheckGeneration += 1
        checkUpdateRepeatedly(generation: updateCheckGeneration)
    }

    func sleep() {
        isSleeping = true
    }

    /// unmount the Settings tree on close so it stops re-diffing on every
    /// store tick; all settings state lives in the stores, so the next
    /// openPreferences remounts pixel-identically
    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === window else {
            return
        }
        settingsHostingView?.rootView = AnyView(EmptyView().frame(width: DesignTokens.Size.settingsWindow.width, height: DesignTokens.Size.settingsWindow.height))
    }

    func applicationWillTerminate(_: Notification) {
        // Insert code here to tear down your application
    }
}

// MARK: UNUserNotificationCenterDelegate

extension AppDelegate: @preconcurrency UNUserNotificationCenterDelegate {
    func userNotificationCenter(_: UNUserNotificationCenter, didReceive _: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                PanelManager.shared.openCentered()
            }
        }
        completionHandler()
    }
}

// MARK: Static Methods

extension AppDelegate {
    static var statusBarHeight: CGFloat {
        NSStatusBar.system.thickness
    }

    static func openPreferences() {
        let delegate = NSApp.delegate as! AppDelegate
        let window = delegate.window!
        // titles are snapshots — refresh in case the language changed
        window.title = "settings.title".localized()
        // mount the Settings tree on demand (unmounted again on close)
        delegate.settingsHostingView?.rootView = AnyView(ContentView().withGlobalEnvironmentObjects())
        // guard against the placeholder having influenced the frame
        window.setContentSize(DesignTokens.Size.settingsWindow)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        NotificationCenter.default.post(name: .StatusBarMenuShouldClose, object: nil)
    }

    static func quit() {
        NSApplication.shared.terminate(self)
    }

    /// Clean Mode (hardware wipe): close the panel so the overlay owns the
    /// screen, then show the confirmation + restoration guide. Reachable from
    /// the panel header and the status-bar context menu.
    static func enterCleanMode() {
        PanelManager.shared.close()
        SharedStore.cleanMode.enter()
    }
}

// MARK: Repeating Methods

extension AppDelegate {
    func refreshSMCRepeatedly(generation: Int) {
        guard !isSleeping, generation == refreshGeneration else {
            return
        }

        NotificationCenter.default.post(name: .SMCShouldRefresh, object: nil)
        // tolerance lets the OS coalesce wakeups; .common keeps the re-arm
        // alive while a menu is open or a window is dragged (like asyncAfter).
        // clamp: a corrupted/zero preference must not become a tight main-loop
        let interval = Double(max(1, preferenceStore.smcRefreshRate))
        let timer = Timer(timeInterval: interval, repeats: false) { [self] _ in
            // main-runloop timer: bridge into the MainActor class
            MainActor.assumeIsolated {
                refreshSMCRepeatedly(generation: generation)
            }
        }
        timer.tolerance = min(interval * 0.1, 0.5)
        RunLoop.main.add(timer, forMode: .common)
    }

    func refreshNetworkRepeatedly(generation: Int) {
        guard !isSleeping, generation == refreshGeneration else {
            return
        }

        NotificationCenter.default.post(name: .NetworkShouldRefresh, object: nil)
        let interval = Double(max(1, preferenceStore.networkRefreshRate))
        let timer = Timer(timeInterval: interval, repeats: false) { [self] _ in
            MainActor.assumeIsolated {
                refreshNetworkRepeatedly(generation: generation)
            }
        }
        timer.tolerance = min(interval * 0.1, 0.5)
        RunLoop.main.add(timer, forMode: .common)
    }

    func checkUpdateRepeatedly(generation: Int) {
        guard !isSleeping, generation == updateCheckGeneration, preferenceStore.upgradeMethod != .none else {
            return
        }

        preferenceStore.checkUpdate()
        let timer = Timer(timeInterval: Double(60 * 60), repeats: false) { [self] _ in
            MainActor.assumeIsolated {
                checkUpdateRepeatedly(generation: generation)
            }
        }
        timer.tolerance = Double(60 * 5)
        RunLoop.main.add(timer, forMode: .common)
    }
}
