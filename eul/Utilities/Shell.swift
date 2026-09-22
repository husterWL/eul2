//
//  Shell.swift
//  eul
//
//  Created by Gao Sun on 2020/8/9.
//  Copyright © 2020 Gao Sun. All rights reserved.
//

import Foundation

/// https://stackoverflow.com/questions/26971240/how-do-i-run-an-terminal-command-in-a-swift-script-e-g-xcodebuild
@discardableResult
func shellData(_ args: [String]) -> Data? {
    let task = Process()
    let pipe = Pipe()
    let error = Pipe()

    Print("shell with", args)

    task.standardOutput = pipe
    task.standardError = error
    task.executableURL = URL(fileURLWithPath: "/bin/bash")
    task.arguments = ["-c"] + args

    var environment = ProcessInfo.processInfo.environment
    environment["LC_ALL"] = "en_US.UTF-8"
    task.environment = environment

    do {
        try task.run()
    } catch {
        print("⚠️ shell executed with error", error)
    }

    let data = pipe.fileHandleForReading.readDataToEndOfFile()

    task.waitUntilExit()

    if task.terminationStatus != 0 {
        return nil
    }

    return data
}

@discardableResult
func shell(_ args: String...) -> String? {
    guard let data = shellData(args) else {
        return nil
    }

    return String(data: data, encoding: .utf8)
}
