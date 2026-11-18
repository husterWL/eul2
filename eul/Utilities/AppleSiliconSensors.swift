//
//  AppleSiliconSensors.swift
//  eul
//
//  Created by Gao Sun on 2026/6/10.
//  Copyright © 2026 Gao Sun. All rights reserved.
//

import Darwin
import Foundation

// Reads temperature sensors on Apple Silicon via the private IOHIDEventSystemClient
// API (the same approach used by stats, Hot, and powermetrics). SMC keys like
// CPU_0_DIE don't exist on M-series chips; their die sensors are exposed as
// AppleVendor-page HID services named "PMU tdie*" / "PMU2 tdie*" instead.
// Symbols are resolved with dlsym so nothing links against private headers.

typealias IOHIDEventSystemClientRef = UnsafeMutableRawPointer
typealias IOHIDServiceClientRef = UnsafeMutableRawPointer
typealias IOHIDEventRef = UnsafeMutableRawPointer

private typealias IOHIDEventSystemClientCreateFunc = @convention(c) (CFAllocator?) -> IOHIDEventSystemClientRef?
private typealias IOHIDEventSystemClientSetMatchingFunc = @convention(c) (IOHIDEventSystemClientRef?, CFDictionary?) -> Void
private typealias IOHIDEventSystemClientCopyServicesFunc = @convention(c) (IOHIDEventSystemClientRef) -> Unmanaged<CFArray>?
private typealias IOHIDServiceClientCopyEventFunc = @convention(c) (IOHIDServiceClientRef, Int64, Int32, Int64) -> IOHIDEventRef?
private typealias IOHIDEventGetFloatValueFunc = @convention(c) (IOHIDEventRef, UInt32) -> Double
private typealias IOHIDServiceClientCopyPropertyFunc = @convention(c) (IOHIDServiceClientRef, CFString) -> Unmanaged<CFString>?

struct AppleSiliconSensorReading {
    let name: String
    let temperature: Double
}

class AppleSiliconSensors: @unchecked Sendable {
    nonisolated(unsafe) static var shared: AppleSiliconSensors?

    private let kIOHIDEventTypeTemperature: Int32 = 15
    private let kHIDPage_AppleVendor: Int32 = 0xFF00
    private let kHIDUsage_AppleVendor_TemperatureSensor: Int32 = 0x0005

    private let eventSystemClientCreate: IOHIDEventSystemClientCreateFunc
    private let eventSystemClientSetMatching: IOHIDEventSystemClientSetMatchingFunc
    private let eventSystemClientCopyServices: IOHIDEventSystemClientCopyServicesFunc
    private let serviceClientCopyEvent: IOHIDServiceClientCopyEventFunc
    private let eventGetFloatValue: IOHIDEventGetFloatValueFunc
    private let serviceClientCopyProperty: IOHIDServiceClientCopyPropertyFunc

    private var systemClient: IOHIDEventSystemClientRef?
    /// Strong reference so the cached service pointers below stay valid
    private var servicesArray: CFArray?
    /// Sensor names are immutable; caching them at setup saves one mach IPC
    /// (CopyProperty) per sensor on every read
    private var cachedServices: [(service: IOHIDServiceClientRef, name: String)] = []
    /// One IOHID scan per refresh tick: SmcControl invalidates this at the top
    /// of its refresh(), every store/view then reads the same snapshot.
    /// All producers/consumers are main-thread, so no locking is needed.
    private var cachedReadings: [AppleSiliconSensorReading]?
    private var lastScanAt = Date.distantPast
    /// each sensor read is a synchronous mach round trip to hidd; temperatures
    /// move slowly, so scanning faster than this is wasted IPC (protects the
    /// 1 s refresh setting — at the default 3 s cadence every tick still scans)
    private static let minimumScanInterval: TimeInterval = 2

    private init?() {
        guard let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW) else {
            print("AppleSiliconSensors: failed to load IOKit")
            return nil
        }

        guard
            let create = dlsym(handle, "IOHIDEventSystemClientCreate"),
            let setMatching = dlsym(handle, "IOHIDEventSystemClientSetMatching"),
            let copyServices = dlsym(handle, "IOHIDEventSystemClientCopyServices"),
            let copyEvent = dlsym(handle, "IOHIDServiceClientCopyEvent"),
            let getFloat = dlsym(handle, "IOHIDEventGetFloatValue"),
            let copyProperty = dlsym(handle, "IOHIDServiceClientCopyProperty")
        else {
            print("AppleSiliconSensors: failed to resolve IOHID symbols")
            dlclose(handle)
            return nil
        }

        eventSystemClientCreate = unsafeBitCast(create, to: IOHIDEventSystemClientCreateFunc.self)
        eventSystemClientSetMatching = unsafeBitCast(setMatching, to: IOHIDEventSystemClientSetMatchingFunc.self)
        eventSystemClientCopyServices = unsafeBitCast(copyServices, to: IOHIDEventSystemClientCopyServicesFunc.self)
        serviceClientCopyEvent = unsafeBitCast(copyEvent, to: IOHIDServiceClientCopyEventFunc.self)
        eventGetFloatValue = unsafeBitCast(getFloat, to: IOHIDEventGetFloatValueFunc.self)
        serviceClientCopyProperty = unsafeBitCast(copyProperty, to: IOHIDServiceClientCopyPropertyFunc.self)

        initializeClient()

        if cachedServices.isEmpty {
            // the created client is a +1 CF object held as a raw pointer —
            // ARC will not clean it up if init bails out here
            releaseClient()
            return nil
        }
    }

    deinit {
        releaseClient()
    }

    private func releaseClient() {
        if let client = systemClient {
            Unmanaged<AnyObject>.fromOpaque(client).release()
            systemClient = nil
        }
        servicesArray = nil
        cachedServices = []
        cachedReadings = nil
        // force the next read after reattach to scan immediately
        lastScanAt = Date.distantPast
    }

    /// HID services can go stale across sleep/wake — re-enumerate so
    /// temperatures don't stay missing until the app is relaunched.
    /// Main thread only (called from the wake handler).
    func reattachAfterWake() {
        releaseClient()
        initializeClient()
    }

    private func initializeClient() {
        let matching: NSDictionary = [
            "PrimaryUsagePage": kHIDPage_AppleVendor,
            "PrimaryUsage": kHIDUsage_AppleVendor_TemperatureSensor,
        ]

        guard let client = eventSystemClientCreate(kCFAllocatorDefault) else {
            print("AppleSiliconSensors: failed to create event system client")
            return
        }
        systemClient = client
        eventSystemClientSetMatching(client, matching as CFDictionary)

        guard let services = eventSystemClientCopyServices(client)?.takeRetainedValue() else {
            print("AppleSiliconSensors: no matching sensor services")
            return
        }
        servicesArray = services

        for index in 0..<CFArrayGetCount(services) {
            if let pointer = CFArrayGetValueAtIndex(services, index) {
                let service = IOHIDServiceClientRef(mutating: pointer)
                // services without a name never produce readings — skip them
                guard let name = serviceClientCopyProperty(service, "Product" as CFString)?.takeRetainedValue() as String? else {
                    continue
                }
                cachedServices.append((service: service, name: name))
            }
        }

        Print("AppleSiliconSensors: cached \(cachedServices.count) sensor services")
    }

    static func initialize() {
        shared = AppleSiliconSensors()
    }

    /// Drops the cached readings so the next read performs a fresh IOHID scan
    /// — unless the last scan is younger than minimumScanInterval, in which
    /// case the snapshot stays and the tick reuses it.
    func invalidate() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard Date().timeIntervalSince(lastScanAt) >= Self.minimumScanInterval else {
            return
        }
        cachedReadings = nil
    }

    func getAllTemperatures() -> [AppleSiliconSensorReading] {
        // the cached snapshot is lock-free by design — enforce the
        // main-thread convention instead of relying on it silently
        dispatchPrecondition(condition: .onQueue(.main))
        if let cachedReadings = cachedReadings {
            return cachedReadings
        }

        var results: [AppleSiliconSensorReading] = []

        for (service, name) in cachedServices {
            guard let event = serviceClientCopyEvent(service, Int64(kIOHIDEventTypeTemperature), 0, 0) else {
                continue
            }
            // Copy-rule (+1) return travels through a raw pointer, so balance it manually
            defer { Unmanaged<AnyObject>.fromOpaque(event).release() }

            // IOHIDEventGetFloatValue field = (type << 16) | offset
            let value = eventGetFloatValue(event, UInt32(kIOHIDEventTypeTemperature << 16))

            if value > 0, value < 150 {
                results.append(AppleSiliconSensorReading(name: name, temperature: value))
            }
        }

        let sorted = results.sorted { $0.name < $1.name }
        cachedReadings = sorted
        lastScanAt = Date()
        return sorted
    }

    /// Average of the per-die PMU temperature sensors; sensor naming varies by
    /// chip generation, hence the prefix fallbacks (one scan, three lookups).
    var cpuTemperature: Double? {
        let readings = getAllTemperatures()
        return average(of: readings, withPrefix: "PMU tdie")
            ?? average(of: readings, withPrefix: "PMU2 tdie")
            ?? average(of: readings, withPrefix: "SOC MTR Temp Sensor")
    }

    /// CPU and GPU share the die on Apple Silicon; the GPU-specific sensors
    /// (when present) are preferred by GpuStore via IOAccelerator statistics.
    var gpuTemperature: Double? {
        cpuTemperature
    }

    var socTemperature: Double? {
        cpuTemperature
    }

    private func average(of readings: [AppleSiliconSensorReading], withPrefix prefix: String) -> Double? {
        let matched = readings.filter { $0.name.hasPrefix(prefix) }
        guard !matched.isEmpty else {
            return nil
        }
        return matched.map { $0.temperature }.reduce(0, +) / Double(matched.count)
    }
}
