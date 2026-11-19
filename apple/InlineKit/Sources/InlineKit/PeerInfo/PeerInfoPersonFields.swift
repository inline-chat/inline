import Foundation

/// The About fields chat info shows for a person, trimmed, and only those the
/// server shared with the viewer. Presence is deliberately absent: Inline
/// shows online and last seen for bots only.
public struct PeerInfoPersonFields: Equatable, Sendable {
  public var bio: String?
  public var username: String?
  /// "4:12 PM (-3 hr)", only when their time zone differs from yours.
  public var localTime: String?
  public var email: String?
  public var phone: String?

  public init(user: User, localTime: (String) -> String? = { TimeZoneFormatter.shared.formatTimeZoneInfo(userTimeZoneId: $0) }) {
    bio = Self.clean(user.bio)
    username = Self.clean(user.username)
    self.localTime = user.timeZone.flatMap(localTime)
    email = Self.clean(user.email)
    phone = Self.clean(user.phoneNumber)
  }

  public var isEmpty: Bool {
    bio == nil && username == nil && localTime == nil && email == nil && phone == nil
  }

  private static func clean(_ value: String?) -> String? {
    guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
    return trimmed
  }
}

/// The line under a person's or thread's name in chat info.
public enum PeerInfoSubtitle {
  /// Mirrors the DM header: focus, then local time. Never presence.
  public static func person(focusActive: Bool, localTime: String?) -> String? {
    if focusActive {
      guard let localTime else { return String(localized: "Notifications silenced") }
      return String(localized: "Notifications silenced · \(localTime)")
    }
    return localTime
  }

  /// "Private thread · 4 members", "Public thread", "Home · 3 members",
  /// "Reply thread". The space and parent are rows below, so they can be clicked.
  public static func thread(subject: PeerInfoSubject, memberCount: Int?) -> String {
    let kind: String = switch subject.kind {
    case .subthread:
      subject.parentMessageId != nil ? String(localized: "Reply thread") : String(localized: "Subthread")
    case .thread where subject.isHomeThread:
      String(localized: "Home thread")
    case .thread where subject.isPublic:
      String(localized: "Public thread")
    default:
      String(localized: "Private thread")
    }
    guard let memberCount, memberCount > 0, !(subject.kind == .thread && subject.isPublic) else { return kind }
    let members = memberCount == 1 ? String(localized: "1 member") : String(localized: "\(memberCount) members")
    return "\(kind) · \(members)"
  }
}
