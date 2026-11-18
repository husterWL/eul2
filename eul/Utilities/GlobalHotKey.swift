//
//  GlobalHotKey.swift
//  eul
//
//  Created by Gao Sun on 2026/6/10.
//  Copyright © 2026 Gao Sun. All rights reserved.
//

import Carbon
import Foundation

/// ⌃⌥E opens the panel regardless of bar state — the always-available escape
/// hatch of the recovery flow (design §2.5). Carbon RegisterEventHotKey needs
/// no accessibility permission and remains the supported mechanism; note
/// macOS 15+ rejects Option-only modifiers, so the default includes Control.
enum GlobalHotKey {
    private nonisolated(unsafe) static var hotKeyRef: EventHotKeyRef?
    private nonisolated(unsafe) static var handlerRef: EventHandlerRef?

    static func register() {
        guard hotKeyRef == nil else {
            return
        }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let handlerStatus = InstallEventHandler(
            GetEventDispatcherTarget(),
            { _, _, _ -> OSStatus in
                DispatchQueue.main.async {
                    // PanelManager is main-actor isolated; this runs on main
                    MainActor.assumeIsolated {
                        if PanelManager.shared.isOpen {
                            PanelManager.shared.close()
                        } else if StatusBarManager.shared.entryItemOccluded {
                            PanelManager.shared.openCentered()
                        } else {
                            PanelManager.shared.open()
                        }
                    }
                }
                return noErr
            },
            1,
            &eventType,
            nil,
            &handlerRef
        )
        // a hotkey registered without a working handler silently never fires
        guard handlerStatus == noErr else {
            print("⚠️ hotkey event handler install failed with status", handlerStatus)
            return
        }

        let hotKeyID = EventHotKeyID(signature: OSType(0x6575_6C31) /* 'eul1' */, id: 1)
        let status = RegisterEventHotKey(
            UInt32(kVK_ANSI_E),
            UInt32(controlKey | optionKey),
            hotKeyID,
            GetEventDispatcherTarget(),
            0,
            &hotKeyRef
        )
        if status != noErr {
            // unconditional: ⌃⌥E being taken by another app is a real user
            // situation, not a debug-only detail (Print only logs with --debug)
            print("⚠️ hotkey ⌃⌥E registration failed with status", status, "(already in use?)")
        }
    }
}
