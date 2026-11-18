//
//  BluetoothStore.swift
//  eul
//
//  Created by Gao Sun on 2021/1/18.
//  Copyright © 2021 Gao Sun. All rights reserved.
//

import Foundation

class BluetoothStore: ObservableObject, @unchecked Sendable {
    @Published var devices: [BluetoothDevice] = []
    private var isFetching = false
    private var lastFetchedAt: Date?
    /// each fetch spawns a ~1-2 s system_profiler subprocess — rapid panel
    /// reopens shouldn't pay that repeatedly
    private static let fetchInterval: TimeInterval = 60

    /// system_profiler blocks for up to ~2 s — never run it on the main
    /// thread; the panel triggers this on open
    func fetchAsync() {
        guard !isFetching else {
            return
        }
        if let lastFetchedAt = lastFetchedAt, Date().timeIntervalSince(lastFetchedAt) < Self.fetchInterval {
            return
        }
        isFetching = true
        // background sampling is utility work, not user-blocking
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = Self.read()
            DispatchQueue.main.async {
                guard let self = self else {
                    return
                }
                self.isFetching = false
                // nil = the fetch FAILED (subprocess error / unparseable
                // output): keep the previous readings and retry on the next
                // open instead of blanking the tile for a full minute
                if let result = result {
                    self.devices = result
                    self.lastFetchedAt = Date()
                }
            }
        }
    }

    /// nil on failure, [] when Bluetooth genuinely reports no connected
    /// devices — the two must not be conflated
    private static func read() -> [BluetoothDevice]? {
        guard let data = shellData(["system_profiler SPBluetoothDataType -json"]) else {
            return nil
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let btArray = json["SPBluetoothDataType"] as? [[String: Any]],
              let first = btArray.first
        else {
            return nil
        }
        guard let connected = first["device_connected"] as? [[String: Any]] else {
            return []
        }

        return connected.compactMap { dict -> BluetoothDevice? in
            // per-key extraction: casting the WHOLE dict to [String: String]
            // dropped the entire device when any single value was non-string
            guard let entry = dict.first,
                  let props = entry.value as? [String: Any]
            else { return nil }

            let name = entry.key
            guard let address = props["device_address"] as? String else { return nil }

            return BluetoothDevice(
                name: name,
                address: address,
                batteryLevel: props["device_batteryLevelMain"] as? String,
                batteryLevelLeft: props["device_batteryLevelLeft"] as? String,
                batteryLevelRight: props["device_batteryLevelRight"] as? String,
                batteryLevelCase: props["device_batteryLevelCase"] as? String
            )
        }
    }
}
