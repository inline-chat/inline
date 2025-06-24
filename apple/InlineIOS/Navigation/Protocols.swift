import SwiftUI

public protocol DestinationType: Hashable {}

public protocol TabType: Hashable, CaseIterable, Identifiable, Sendable {
  var icon: String { get }
}

public protocol SheetType: Hashable, Identifiable {}
