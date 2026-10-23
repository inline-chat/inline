import SwiftUI

public protocol DestinationType: Hashable, Codable {
  /// Work to finish before the destination is shown, so it renders complete in its first frame.
  /// Nil shows it immediately.
  @MainActor func preparationBeforeShowing() -> (@MainActor @Sendable () async -> Void)?
}

public extension DestinationType {
  @MainActor func preparationBeforeShowing() -> (@MainActor @Sendable () async -> Void)? { nil }
}

public protocol TabType: Hashable, CaseIterable, Identifiable, Sendable, Codable {
  var icon: String { get }
}

public protocol SheetType: Hashable, Identifiable, Codable {}
