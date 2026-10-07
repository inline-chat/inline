import Foundation
import InlineProtocol

/// Local navigation history used only as a stable tie-breaker after live Grid
/// activity. It does not own eligibility or presence; the server summary does.
@MainActor
final class GridHomePreferences {
  private let defaults: UserDefaults
  private let key = "grid.home.lastOpenedSpaces"

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  func recordOpened(spaceID: Int64) {
    var values = timestamps
    values[String(spaceID)] = Date().timeIntervalSince1970
    defaults.set(values, forKey: key)
  }

  func ordered(_ spaces: [GridHomeSpace]) -> [GridHomeSpace] {
    let timestamps = timestamps
    return spaces.sorted { lhs, rhs in
      let lhsActive = lhs.activeAvatarCount > 0
      let rhsActive = rhs.activeAvatarCount > 0
      if lhsActive != rhsActive { return lhsActive }
      if lhs.latestActivityAt != rhs.latestActivityAt {
        return lhs.latestActivityAt > rhs.latestActivityAt
      }
      let lhsOpened = timestamps[String(lhs.spaceID)] ?? 0
      let rhsOpened = timestamps[String(rhs.spaceID)] ?? 0
      if lhsOpened != rhsOpened { return lhsOpened > rhsOpened }
      return lhs.spaceID < rhs.spaceID
    }
  }

  private var timestamps: [String: Double] {
    defaults.dictionary(forKey: key) as? [String: Double] ?? [:]
  }
}
