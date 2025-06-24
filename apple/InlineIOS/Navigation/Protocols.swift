import SwiftUI

public protocol DestinationType: Hashable, Codable {}

public protocol TabType: Hashable, CaseIterable, Identifiable, Sendable, Codable {
  var icon: String { get }
}

public protocol SheetType: Hashable, Identifiable, Codable {}
