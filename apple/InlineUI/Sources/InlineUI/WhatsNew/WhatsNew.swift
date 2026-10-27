import Foundation
import Observation

public struct WhatsNewItem: Identifiable, Sendable {
  public struct Platforms: OptionSet, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
      self.rawValue = rawValue
    }

    public static let iOS = Platforms(rawValue: 1 << 0)
    public static let macOS = Platforms(rawValue: 1 << 1)
    public static let all: Platforms = [.iOS, .macOS]

    public static var current: Platforms {
#if os(macOS)
      .macOS
#else
      .iOS
#endif
    }
  }

  public let systemImage: String
  public let title: String
  public let detail: String
  public let platforms: Platforms

  public var id: String { title }

  public init(systemImage: String, title: String, detail: String, platforms: Platforms = .all) {
    self.systemImage = systemImage
    self.title = title
    self.detail = detail
    self.platforms = platforms
  }
}

/// A curated set of highlights shown once per device after an update.
public struct WhatsNewAnnouncement: Identifiable, Sendable {
  public static let changelogURL = URL(string: "https://inline.chat/docs/changelog")!

  /// Stable key stored once seen. Use a new id for each announcement.
  public let id: String
  public let items: [WhatsNewItem]

  public init(id: String, items: [WhatsNewItem]) {
    self.id = id
    self.items = items
  }

  public var itemsForCurrentPlatform: [WhatsNewItem] {
    items.filter { $0.platforms.contains(.current) }
  }
}

@MainActor
@Observable
public final class WhatsNewStore {
  public static let shared = WhatsNewStore(announcement: .current)

  private static let lastSeenIDKey = "whatsNew.lastSeenId"

  /// The announcement bundled with this build, if it has highlights for this platform.
  public let announcement: WhatsNewAnnouncement?

  /// Set until the bundled announcement has been seen or dismissed on this device.
  public private(set) var pending: WhatsNewAnnouncement?

  @ObservationIgnored private let defaults: UserDefaults

  public init(announcement: WhatsNewAnnouncement?, defaults: UserDefaults = .standard) {
    let announcement = announcement.flatMap { $0.itemsForCurrentPlatform.isEmpty ? nil : $0 }
    self.announcement = announcement
    self.defaults = defaults
    if let announcement, defaults.string(forKey: Self.lastSeenIDKey) != announcement.id {
      pending = announcement
    }
  }

  /// Records the bundled announcement as seen. Also called when sign-in starts so
  /// new users don't see highlights for features they've never missed.
  public func markSeen() {
    guard let announcement else { return }
    defaults.set(announcement.id, forKey: Self.lastSeenIDKey)
    pending = nil
  }
}
