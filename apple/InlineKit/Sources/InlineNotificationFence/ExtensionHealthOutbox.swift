import Foundation

/// Outcome counts from app extensions, which don't run Sentry. Extensions add to one shared
/// app-group record; the app drains it and sends each distinct outcome as one health event with
/// its count. Names and values are fixed program vocabulary, and the app's health event
/// allow-list drops anything else.
public struct ExtensionHealthOutbox: Sendable {
  public struct Entry: Codable, Equatable, Sendable {
    public var event: String
    public var fields: [String: String]
    public var count: Int
  }

  public static let shared = ExtensionHealthOutbox(suiteName: "group.chat.inline")
  static let key = "extension-health-v1"
  /// Distinct outcomes kept between drains; later new outcomes are dropped, counts still grow.
  static let maxEntries = 64

  private let suiteName: String

  public init(suiteName: String) {
    self.suiteName = suiteName
  }

  /// Best effort: an extension and the app can race on the shared record and lose a count.
  public func record(_ event: String, _ fields: [String: String] = [:]) {
    guard let defaults = UserDefaults(suiteName: suiteName) else { return }
    var entries = Self.decode(defaults.data(forKey: Self.key))
    if let index = entries.firstIndex(where: { $0.event == event && $0.fields == fields }) {
      entries[index].count += 1
    } else if entries.count < Self.maxEntries {
      entries.append(Entry(event: event, fields: fields, count: 1))
    } else {
      return
    }
    guard let data = try? JSONEncoder().encode(entries) else { return }
    defaults.set(data, forKey: Self.key)
  }

  public func drain() -> [Entry] {
    guard let defaults = UserDefaults(suiteName: suiteName) else { return [] }
    let entries = Self.decode(defaults.data(forKey: Self.key))
    defaults.removeObject(forKey: Self.key)
    return entries
  }

  private static func decode(_ data: Data?) -> [Entry] {
    guard let data, let entries = try? JSONDecoder().decode([Entry].self, from: data) else { return [] }
    return entries
  }
}
