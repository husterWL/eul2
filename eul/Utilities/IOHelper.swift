//
//  IOHelper.swift
//  eul
//
//  Created by Gao Sun on 2021/1/23.
//  Copyright © 2021 Gao Sun. All rights reserved.
//

import Darwin
import Foundation

enum IOHelper {
    static func getProperties(entry: io_object_t) -> NSDictionary? {
        var serviceDict: Unmanaged<CFMutableDictionary>?

        defer {
            serviceDict?.release()
        }

        if IORegistryEntryCreateCFProperties(entry, &serviceDict, kCFAllocatorDefault, 0) != kIOReturnSuccess {
            return nil
        }

        return serviceDict?.takeUnretainedValue()
    }

    static func getPropertyList(for service: String) -> [NSDictionary]? {
        var iterator = io_iterator_t()

        defer {
            IOObjectRelease(iterator)
        }

        let port: mach_port_t
        if #available(macOS 12.0, *) {
            port = kIOMainPortDefault
        } else {
            port = kIOMasterPortDefault
        }

        guard IOServiceGetMatchingServices(
            port,
            IOServiceMatching(service),
            &iterator
        ) == kIOReturnSuccess else {
            return nil
        }

        var propertyList = [NSDictionary]()
        var entry = IOIteratorNext(iterator)

        while entry != 0 {
            if let properties = getProperties(entry: entry) {
                propertyList.append(properties)
            }
            IOObjectRelease(entry)
            entry = IOIteratorNext(iterator)
        }

        return propertyList
    }

    // MARK: - Battery hardware

    /// mAh-scale battery values read straight from the AppleSmartBattery
    /// registry. Every field is optional on purpose: macOS 26/27 moved the raw
    /// capacities out of the service's top level into nested `BatteryData`
    /// dictionaries (and the pack/bank/cell entries carry their own copy), so a
    /// value that cannot be found must stay absent instead of collapsing to 0 —
    /// which is exactly what surfaced as "design capacity 0 mAh" next to an
    /// "N/A" health reading.
    struct BatteryHardware {
        var currentCapacity: Int?
        var maxCapacity: Int?
        var designCapacity: Int?
        var cycleCount: Int?

        var hasCapacity: Bool {
            maxCapacity != nil || designCapacity != nil
        }
    }

    /// Raw mAh keys first, generic keys last. The generic `MaxCapacity` /
    /// `CurrentCapacity` are percentages on Apple Silicon (100 / 80), which is
    /// why they are only ever accepted when nothing better exists and the value
    /// passes the mAh sanity check.
    private static let currentCapacityKeys = ["AppleRawCurrentCapacity", "RemainingCapacity", "CurrentCapacity"]
    private static let maxCapacityKeys = ["AppleRawMaxCapacity", "FullChargeCapacity", "NominalChargeCapacity", "MaxCapacity"]
    private static let designCapacityKeys = ["DesignCapacity"]
    private static let cycleCountKeys = ["CycleCount"]

    /// A charge percentage is at most 100 while every real Mac battery reports
    /// thousands of mAh, so anything at or below 100 is a percentage that would
    /// otherwise be rendered as a nonsensical "100 mAh".
    private static let minimumPlausibleMilliampHours = 101

    static func batteryHardware() -> BatteryHardware {
        var values = [String: Int]()
        // every subclass entry (pack/bank/cell) matches the query as well and
        // holds its own copy of the payload, so merge them all and let the key
        // priority decide which one wins
        for properties in getPropertyList(for: "AppleSmartBattery") ?? [] {
            collectIntegers(from: properties, depth: 0, into: &values)
        }

        return BatteryHardware(
            currentCapacity: pick(from: values, keys: currentCapacityKeys, minimum: minimumPlausibleMilliampHours),
            maxCapacity: pick(from: values, keys: maxCapacityKeys, minimum: minimumPlausibleMilliampHours),
            designCapacity: pick(from: values, keys: designCapacityKeys, minimum: minimumPlausibleMilliampHours),
            cycleCount: pick(from: values, keys: cycleCountKeys, minimum: 1)
        )
    }

    /// Depth-limited walk over the property tree — macOS 27 nests the payload
    /// inside `BatteryData`, with `LifetimeData` below that.
    private static func collectIntegers(from dictionary: NSDictionary, depth: Int, into values: inout [String: Int]) {
        for (key, value) in dictionary {
            guard let key = key as? String else {
                continue
            }
            if let nested = value as? NSDictionary, depth < 3 {
                collectIntegers(from: nested, depth: depth + 1, into: &values)
            } else if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
                if values[key] == nil {
                    values[key] = number.intValue
                }
            }
        }
    }

    private static func pick(from values: [String: Int], keys: [String], minimum: Int) -> Int? {
        for key in keys {
            if let value = values[key], value >= minimum {
                return value
            }
        }
        return nil
    }

    // MARK: - Process sampling

    /// `proc_pidinfo` and `proc_pid_rusage` report times in mach absolute ticks
    /// — nanoseconds on Intel, 24 MHz on Apple Silicon — so one factor
    /// normalizes both to nanoseconds.
    static let machTimebaseFactor: Double = {
        var info = mach_timebase_info()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom)
    }()

    struct ProcessSample {
        let pid: pid_t
        let name: String
        /// resident memory in bytes
        let residentBytes: UInt64
        /// cumulative user + system CPU time in seconds
        let cpuSeconds: Double
    }

    /// One `proc_pidinfo` call per process returns resident memory *and*
    /// cumulative CPU time, so every process-reading feature (the panel's top
    /// lists and the runaway detector) shares a single walk. This replaces the
    /// `top(1)` subprocesses plus text parsing the panel used to do, which tied
    /// the numbers to the system locale and to `top`'s column layout.
    static func processSamples() -> [ProcessSample] {
        let expected = proc_listallpids(nil, 0)
        guard expected > 0 else {
            return []
        }
        var pids = [pid_t](repeating: 0, count: Int(expected) + 32)
        let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard filled > 0 else {
            return []
        }

        var samples = [ProcessSample]()
        samples.reserveCapacity(Int(filled))
        let taskInfoSize = Int32(MemoryLayout<proc_taskinfo>.size)
        for index in 0..<Int(filled) {
            let pid = pids[index]
            // pid 0 is kernel_task: `top` listed it, but it is not a real
            // process and its figures are not comparable
            guard pid > 0 else {
                continue
            }
            var info = proc_taskinfo()
            guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, taskInfoSize) == taskInfoSize else {
                continue
            }
            samples.append(ProcessSample(
                pid: pid,
                name: processName(pid),
                residentBytes: info.pti_resident_size,
                cpuSeconds: Double(info.pti_total_user &+ info.pti_total_system) * machTimebaseFactor / 1_000_000_000
            ))
        }
        return samples
    }

    static func processName(_ pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        let length = proc_name(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else {
            return "pid \(pid)"
        }
        return String(cString: buffer)
    }
}
