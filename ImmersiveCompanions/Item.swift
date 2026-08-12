//
//  Item.swift
//  ImmersiveCompanions
//
//  Created by Vanardois Nicolas on 12/08/2026.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
