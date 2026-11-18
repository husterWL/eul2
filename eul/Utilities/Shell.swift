//
//  Shell.swift
//  eul
//
//  Created by Gao Sun on 2020/8/9.
//  Copyright © 2020 Gao Sun. All rights reserved.
//

import Foundation

/// Runs a command via /bin/bash -c and returns its stdout, or nil on any
/// failure. Hardened failure paths (review P0-2):
/// - a failed spawn returns immediately instead of blocking forever on a
///   pipe whose write end the parent still holds;
/// - stderr goes to /dev/null — an unread stderr pipe used to be able to
///   deadlock the child once it filled the pipe buffer;
/// - the whole call is bounded by a timeout; a hung child is terminated
///   instead of freezing the caller's queue (nettop's serial sample queue
///   used to stay wedged until relaunch).
@discardableResult
func shellData(_ args: [String], timeout: TimeInterval = 10) -> Data? {
    let task = Process()
    let pipe = Pipe()

    Print("shell with", args)

    task.standardOutput = pipe
    task.standardError = FileHandle.nullDevice
    task.executableURL = URL(fileURLWithPath: "/bin/bash")
    task.arguments = ["-c"] + args

    var environment = ProcessInfo.processInfo.environment
    environment["LC_ALL"] = "en_US.UTF-8"
    task.environment = environment

    // Collect stdout incrementally so a hung child can be terminated on
    // timeout without the reader blocking past the deadline. The handler is
    // a @Sendable closure, so the mutable reader state lives in a
    // lock-guarded box instead of bare captured locals (Swift 6).
    final class ReaderState: @unchecked Sendable {
        let lock = NSLock()
        var data = Data()
        var reachedEOF = false
    }
    let state = ReaderState()
    pipe.fileHandleForReading.readabilityHandler = { handle in
        let chunk = handle.availableData
        state.lock.lock()
        if chunk.isEmpty {
            state.reachedEOF = true
        } else {
            state.data.append(chunk)
        }
        state.lock.unlock()
    }

    let exited = DispatchSemaphore(value: 0)
    task.terminationHandler = { _ in
        exited.signal()
    }

    do {
        try task.run()
    } catch {
        print("⚠️ shell executed with error", error)
        pipe.fileHandleForReading.readabilityHandler = nil
        return nil
    }

    if exited.wait(timeout: .now() + timeout) == .timedOut {
        print("⚠️ shell timed out after \(timeout)s, terminating:", args)
        task.terminate()
        // give SIGTERM a moment; a bash child that ignores it must not
        // wedge the caller — drop the result and move on
        _ = exited.wait(timeout: .now() + 2)
        pipe.fileHandleForReading.readabilityHandler = nil
        if task.isRunning {
            return nil
        }
    }

    // the child has exited (or was terminated): wait for the reader to see
    // EOF so the handler stays the ONLY reader of the pipe (no concurrent
    // reads racing on the same descriptor), then take what it collected
    let drainDeadline = Date().addingTimeInterval(1)
    while Date() < drainDeadline {
        state.lock.lock()
        let eof = state.reachedEOF
        state.lock.unlock()
        if eof {
            break
        }
        usleep(10000)
    }
    pipe.fileHandleForReading.readabilityHandler = nil

    state.lock.lock()
    let data = state.data
    state.lock.unlock()

    guard task.terminationStatus == 0 else {
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
