import Foundation

public enum SidebarCleanupPolicy: Equatable, Sendable {
  case manual
  case automatic(timeout: TimeInterval)

  public static let manualOpenedAge: TimeInterval = 6 * 60 * 60
  public static let manualActivityAge: TimeInterval = 3 * 60 * 60

  public func shouldClose(
    now: Date,
    openedAt: Date,
    lastActivityAt: Date?,
    latestOwnMessageAt: Date?,
    isEmptyUntitled: Bool
  ) -> Bool {
    if isEmptyUntitled {
      return true
    }

    switch self {
    case .manual:
      let openedCutoff = now.addingTimeInterval(-Self.manualOpenedAge)
      let activityCutoff = now.addingTimeInterval(-Self.manualActivityAge)
      return openedAt <= openedCutoff
        && (lastActivityAt ?? openedAt) <= activityCutoff

    case let .automatic(timeout):
      let cutoff = now.addingTimeInterval(-max(timeout, 0))
      return max(openedAt, latestOwnMessageAt ?? openedAt) <= cutoff
    }
  }
}
