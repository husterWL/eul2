//
//  SharedEntry.swift
//  eul
//
//  Created by Gao Sun on 2020/11/5.
//  Copyright © 2020 Gao Sun. All rights reserved.
//

import Foundation
import WidgetKit

/// Sendable: entries cross process/thread boundaries (app main thread writes
/// the container, widget extensions read it on WidgetKit's queues) — they are
/// pure value types, so the conformance is free and Swift 6 requires it for
/// the `static let sample` previews.
public protocol SharedEntry: Codable, Sendable {
    static var containerKey: String { get }
}
