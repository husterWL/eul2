//
//  FanStore.swift
//  eul
//
//  Created by Gao Sun on 2020/6/29.
//  Copyright © 2020 Gao Sun. All rights reserved.
//

import Foundation

class FanStore: ObservableObject, Refreshable, @unchecked Sendable {
    @Published var fans: [FanData] = []

    @objc func refresh() {
        let newFans = SmcControl.shared.fans
        // publish only on real change: fanless Macs never publish, and a
        // steady RPM reading doesn't invalidate observing views every tick
        guard newFans != fans else {
            return
        }
        fans = newFans
    }

    init() {
        initObserver(for: .StoreShouldRefresh)
    }
}
