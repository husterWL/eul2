//
//  AppDelegate.swift
//  SelfUpdate
//
//  Created by Gao Sun on 2021/2/12.
//  Copyright © 2021 Gao Sun. All rights reserved.
//

import Cocoa
import Security
import SwiftUI

@main
class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    let fileManager = FileManager.default

    static func quit() {
        NSApplication.shared.terminate(self)
    }

    func update() {
        defer {
            AppDelegate.quit()
        }

        let arguments = CommandLine.arguments
        guard arguments.count >= 4 else {
            print("usage: SelfUpdate <tempDir> <installDir> <pid>")
            return
        }
        let newAppUrl = URL(fileURLWithPath: arguments[1]).appendingPathComponent("eul.app")
        let appUrl = URL(fileURLWithPath: arguments[2]).appendingPathComponent("eul.app")
        let pidArg = pid_t(arguments[3])

        guard
            let pid = pidArg,
            let currentApp = NSWorkspace.shared.runningApplications.first(where: { $0.processIdentifier == pid })
        else {
            print("current app not found with pid", pidArg ?? "N/A")
            return
        }

        var isDirectory: ObjCBool = false

        guard fileManager.fileExists(atPath: newAppUrl.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            print("new app not found at", newAppUrl)
            return
        }

        // Verify BEFORE terminating anything: a rejected update leaves the
        // running app untouched.
        guard verifyNewApp(at: newAppUrl, replacing: appUrl) else {
            print("update aborted: verification failed")
            return
        }

        print("terminating current app")
        guard currentApp.terminate() || currentApp.forceTerminate() else {
            print("cannot terminate current app")
            return
        }

        do {
            // Stage on the SAME volume as the destination, then swap
            // atomically. A failed copy can never leave the user without an
            // app (the old remove-then-copy did exactly that).
            let stagingUrl = appUrl.deletingLastPathComponent()
                .appendingPathComponent(".eul-update-\(UUID().uuidString).app")
            print("staging new app at", stagingUrl)
            try fileManager.copyItem(at: newAppUrl, to: stagingUrl)
            print("atomically replacing", appUrl)
            // default options: the system keeps a transient backup and removes
            // it after a successful swap — a failed copy can never leave the
            // user without an app
            _ = try fileManager.replaceItemAt(
                appUrl,
                withItemAt: stagingUrl,
                backupItemName: nil,
                options: []
            )
        } catch {
            print("error when setting up new app", error)
            // the old bundle is intact (atomic swap); relaunch it so the
            // user is not left with nothing
            NSWorkspace.shared.open(appUrl)
            return
        }

        print("opening app")
        guard NSWorkspace.shared.open(appUrl) else {
            print("failed to open app")
            return
        }

        print("update fininshed")
    }

    // MARK: - Update verification

    private static let expectedBundleID = "com.gaosun.eul"

    private func bundleIdentifier(at url: URL) -> String? {
        Bundle(url: url)?.bundleIdentifier
    }

    private func signingInfo(at url: URL) -> [String: Any]? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let staticCode = code else {
            return nil
        }
        var info: CFDictionary?
        guard
            SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
            let dict = info as? [String: Any]
        else {
            return nil
        }
        return dict
    }

    private func teamIdentifier(at url: URL) -> String? {
        signingInfo(at: url)?[kSecCodeInfoTeamIdentifier as String] as? String
    }

    private func isSigned(at url: URL) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let staticCode = code else {
            return false
        }
        return SecStaticCodeCheckValidity(staticCode, SecCSFlags(rawValue: kSecCSCheckAllArchitectures), nil) == errSecSuccess
    }

    private func makeRequirement(_ text: String) -> SecRequirement? {
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess else {
            return nil
        }
        return requirement
    }

    /// Gate the install on identity + signature. A signed current app pins the
    /// update to its own team; an unsigned (development) current app accepts a
    /// validly signed release, or another unsigned dev build (with a warning).
    private func verifyNewApp(at newAppUrl: URL, replacing appUrl: URL) -> Bool {
        guard let newID = bundleIdentifier(at: newAppUrl), newID == Self.expectedBundleID else {
            print("update rejected: new app bundle identifier mismatch")
            return false
        }

        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures)
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(newAppUrl as CFURL, [], &code) == errSecSuccess, let staticCode = code else {
            print("update rejected: cannot read new app code signature")
            return false
        }

        if let team = teamIdentifier(at: appUrl), !team.isEmpty {
            guard let req = makeRequirement("anchor apple generic and identifier \"\(Self.expectedBundleID)\" and certificate leaf[subject.OU] = \"\(team)\""),
                  SecStaticCodeCheckValidity(staticCode, flags, req) == errSecSuccess
            else {
                print("update rejected: new app not signed by the same team")
                return false
            }
            return true
        }

        if isSigned(at: newAppUrl) {
            guard let req = makeRequirement("anchor apple generic and identifier \"\(Self.expectedBundleID)\""),
                  SecStaticCodeCheckValidity(staticCode, flags, req) == errSecSuccess
            else {
                print("update rejected: new app signature invalid")
                return false
            }
            return true
        }

        print("update: unsigned development build, signature verification skipped")
        return true
    }

    func applicationDidFinishLaunching(_: Notification) {
        update()

        guard CommandLine.arguments.contains("--debug") else {
            return
        }

        // Create the SwiftUI view that provides the window contents.
        let contentView = ContentView()

        // Create the window and set the content view.
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 300),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("Main Window")
        window.contentView = NSHostingView(rootView: contentView)
        window.makeKeyAndOrderFront(nil)
    }

    func applicationWillTerminate(_: Notification) {
        // Insert code here to tear down your application
    }
}
