import Foundation

/// How Agent Settings arranges a provider's settings document: the choices in
/// the provider's own sections, then every meter (usage limits, context) in
/// one group, and one access note when every locked control shares a reason.
public struct BotChatSettingsLayout: Equatable, Sendable {
  public struct Meter: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    /// "42%".
    public let value: String
    /// "Resets at 2:30 PM", "120k / 200k".
    public let detail: String?
    public let fraction: Double

    public var isHigh: Bool { fraction >= 0.9 }
  }

  /// Sections with the choices left after meters and hidden items move out.
  public let sections: [BotChatSettingsModel.Section]
  public let meters: [Meter]
  /// Compact, shown beside the context meter.
  public let contextAction: BotChatSettingsModel.Item?
  /// A v1 bridge's one-line usage summary, with its details.
  public let usageSummary: BotChatSettingsModel.Item?
  public let accessNote: String?

  public var hasUsage: Bool { !meters.isEmpty || usageSummary != nil }

  /// - Parameter hiddenItemIDs: items another source already shows, like an
  ///   agent thread's own folder, model and reasoning.
  public init(
    document: BotChatSettingsModel.Document,
    hiding hiddenItemIDs: Set<String> = [],
    now: Date = .now
  ) {
    var usageMeters: [Meter] = []
    var contextMeter: Meter?
    var usageSummary: BotChatSettingsModel.Item?
    var compact: BotChatSettingsModel.Item?
    var sections: [BotChatSettingsModel.Section] = []

    for section in document.sections {
      var items: [BotChatSettingsModel.Item] = []
      for item in section.items where !hiddenItemIDs.contains(item.id) {
        if let window = Self.usageWindow(item, now: now) {
          usageMeters.append(window)
        } else if let context = Self.contextMeter(item) {
          contextMeter = context
        } else if item.id == ComposeAgentSettingsItem.usage {
          usageSummary = item
        } else {
          if item.id == ComposeAgentSettingsItem.compact { compact = item }
          items.append(item)
        }
      }
      sections.append(.init(id: section.id, title: section.title, description: section.description, items: items))
    }

    // Compact belongs beside the context it frees; without a reported
    // context it stays where the provider put it.
    let contextAction = contextMeter == nil ? nil : compact
    if let contextAction {
      sections = sections.map { section in
        .init(
          id: section.id,
          title: section.title,
          description: section.description,
          items: section.items.filter { $0.id != contextAction.id }
        )
      }
    }

    self.sections = sections.filter { !$0.items.isEmpty }
    meters = usageMeters + (contextMeter.map { [$0] } ?? [])
    self.contextAction = contextAction
    self.usageSummary = usageSummary
    accessNote = Self.sharedDisabledReason(in: self.sections.flatMap(\.items))
  }

  /// The reason most locked choices give (two or more), shown once instead
  /// of per row. A reason only one control gives stays with that control.
  public static func sharedDisabledReason(in items: [BotChatSettingsModel.Item]) -> String? {
    let reasons = items.filter(\.isDisabled).compactMap(\.disabledReason)
    var counts: [String: Int] = [:]
    for reason in reasons { counts[reason, default: 0] += 1 }
    guard let top = counts.values.max(), top >= 2 else { return nil }
    // First-seen order breaks ties, so the note doesn't flip between renders.
    return reasons.first { counts[$0] == top }
  }

  // MARK: Meters

  /// `account.usage.window:<minutes>:<used %>:<resets at>:<index>`.
  static func usageWindow(_ item: BotChatSettingsModel.Item, now: Date) -> Meter? {
    let parts = item.id.split(separator: ":", omittingEmptySubsequences: false)
    guard parts.count >= 4, parts[0] == ComposeAgentSettingsItem.usageWindow,
          let used = Int(parts[2]), let resets = Int(parts[3])
    else { return nil }
    let percent = min(100, max(0, used))
    let resetsAt = resets > 0 ? Date(timeIntervalSince1970: TimeInterval(resets)) : nil
    return Meter(
      id: item.id,
      title: item.label ?? String(localized: "Limit"),
      value: "\(percent)%",
      detail: resetsAt.flatMap { $0 > now ? resetText($0, now: now) : nil },
      fraction: Double(percent) / 100
    )
  }

  /// `session.context:<used tokens>:<window>`.
  static func contextMeter(_ item: BotChatSettingsModel.Item) -> Meter? {
    let parts = item.id.split(separator: ":")
    guard parts.count == 3, parts[0] == ComposeAgentSettingsItem.context,
          let used = Int(parts[1]), let window = Int(parts[2]), window > 0
    else { return nil }
    let fraction = min(1, Double(used) / Double(window))
    return Meter(
      id: item.id,
      title: String(localized: "Context"),
      value: "\(Int((fraction * 100).rounded()))%",
      detail: "\(ComposeAgentTokens.text(used)) / \(ComposeAgentTokens.text(window))",
      fraction: fraction
    )
  }

  /// "Resets at 2:30 PM" today, "Resets Tue 9:30 AM" this week, else a date.
  public static func resetText(_ date: Date, now: Date = .now) -> String {
    let calendar = Calendar.current
    if calendar.isDate(date, inSameDayAs: now) {
      return String(localized: "Resets at \(date.formatted(date: .omitted, time: .shortened))")
    }
    if date.timeIntervalSince(now) < 6 * 24 * 3600 {
      let day = date.formatted(.dateTime.weekday(.abbreviated))
      return String(localized: "Resets \(day) \(date.formatted(date: .omitted, time: .shortened))")
    }
    return String(localized: "Resets \(date.formatted(.dateTime.month(.abbreviated).day()))")
  }
}
