import Combine
import Foundation
import InlineProtocol

/// Who can see one piece of the user's information. The user always sees their own.
public struct PrivacyRuleValue: Codable, Equatable, Hashable, Sendable {
  public enum Audience: String, Codable, CaseIterable, Sendable {
    case everyone
    case nobody
  }

  public var audience: Audience
  /// People who can see it when the audience is nobody.
  public var alwaysShare: [Int64]
  /// People who cannot see it when the audience is everyone.
  public var neverShare: [Int64]

  public init(audience: Audience, alwaysShare: [Int64] = [], neverShare: [Int64] = []) {
    self.audience = audience
    self.alwaysShare = alwaysShare
    self.neverShare = neverShare
  }

  /// The rule an account without one has, derived from the legacy flag.
  public static func legacy(share: Bool) -> PrivacyRuleValue {
    PrivacyRuleValue(audience: share ? .everyone : .nobody)
  }

  /// The exception list that applies to the current audience. Both lists are
  /// kept, so switching the audience back restores the other list.
  public var exceptions: [Int64] {
    get { audience == .everyone ? neverShare : alwaysShare }
    set {
      if audience == .everyone { neverShare = newValue } else { alwaysShare = newValue }
    }
  }

  /// Short description for a settings row, such as "Everyone except 2".
  public var summary: String {
    let count = exceptions.count
    switch audience {
      case .everyone: return count == 0 ? "Everyone" : "Everyone except \(count)"
      case .nobody: return count == 0 ? "Nobody" : (count == 1 ? "1 person" : "\(count) people")
    }
  }

  /// Title for the list that applies to the current audience.
  public var exceptionsTitle: String {
    audience == .everyone ? "Never Share With" : "Always Share With"
  }

  init(from rule: InlineProtocol.PrivacyRule) {
    // An unknown audience fails closed.
    audience = rule.audience == .everyone ? .everyone : .nobody
    alwaysShare = rule.alwaysShare.compactMap(Self.userID)
    neverShare = rule.neverShare.compactMap(Self.userID)
  }

  func toProtocol() -> InlineProtocol.PrivacyRule {
    .with {
      $0.audience = audience == .everyone ? .everyone : .nobody
      $0.alwaysShare = alwaysShare.map(Self.target)
      $0.neverShare = neverShare.map(Self.target)
    }
  }

  private static func userID(_ target: InlineProtocol.PrivacyTarget) -> Int64? {
    if case let .userID(id) = target.target { return id }
    return nil
  }

  private static func target(_ userID: Int64) -> InlineProtocol.PrivacyTarget {
    .with { $0.userID = userID }
  }
}

public final class PrivacySettingsManager: ObservableObject, Codable, @unchecked Sendable {
  @Published public var shareTimeZone: Bool
  @Published public var appearInGlobalSearch: Bool
  /// The server's time zone rule. Nil until a server sends one; saves then
  /// carry only the legacy flag so they cannot erase lists set elsewhere.
  @Published public private(set) var timeZoneRule: PrivacyRuleValue?
  /// The server's Focus rule. Nil until a server sends one, and saves then omit it.
  @Published public private(set) var focusStatusRule: PrivacyRuleValue?

  public init(
    shareTimeZone: Bool = true,
    appearInGlobalSearch: Bool = true,
    timeZoneRule: PrivacyRuleValue? = nil,
    focusStatusRule: PrivacyRuleValue? = nil
  ) {
    self.shareTimeZone = shareTimeZone
    self.appearInGlobalSearch = appearInGlobalSearch
    self.timeZoneRule = timeZoneRule
    self.focusStatusRule = focusStatusRule
  }

  convenience init(from settings: InlineProtocol.PrivacySettings) {
    self.init(
      shareTimeZone: settings.hasShareTimeZone ? settings.shareTimeZone : true,
      appearInGlobalSearch: settings.hasAppearInGlobalSearch ? settings.appearInGlobalSearch : true,
      timeZoneRule: settings.hasTimeZone ? PrivacyRuleValue(from: settings.timeZone) : nil,
      focusStatusRule: settings.hasFocusStatus ? PrivacyRuleValue(from: settings.focusStatus) : nil
    )
  }

  /// Focus status is opt-in: nobody sees it until the user adds an audience.
  public var effectiveFocusStatusRule: PrivacyRuleValue {
    focusStatusRule ?? PrivacyRuleValue(audience: .nobody)
  }

  /// Whether anyone could see Focus, so devices should report it.
  public var sharesFocusStatus: Bool {
    let rule = effectiveFocusStatusRule
    return rule.audience == .everyone || !rule.alwaysShare.isEmpty
  }

  public func setFocusStatusRule(_ rule: PrivacyRuleValue) {
    if focusStatusRule != rule { focusStatusRule = rule }
  }

  func replaceFocusStatusRule(_ rule: PrivacyRuleValue?) {
    if focusStatusRule != rule { focusStatusRule = rule }
  }

  /// The rule to show and edit, derived from the legacy flag when needed.
  public var effectiveTimeZoneRule: PrivacyRuleValue {
    timeZoneRule ?? .legacy(share: shareTimeZone)
  }

  public func setTimeZoneRule(_ rule: PrivacyRuleValue) {
    guard rule != timeZoneRule else { return }
    timeZoneRule = rule
    let share = rule.audience == .everyone
    if shareTimeZone != share { shareTimeZone = share }
  }

  /// Applies a server value without treating it as a local edit.
  func replaceTimeZoneRule(_ rule: PrivacyRuleValue?) {
    if timeZoneRule != rule { timeZoneRule = rule }
  }

  func toProtocol() -> InlineProtocol.PrivacySettings {
    .with {
      $0.shareTimeZone = shareTimeZone
      $0.appearInGlobalSearch = appearInGlobalSearch
      if let timeZoneRule { $0.timeZone = timeZoneRule.toProtocol() }
      if let focusStatusRule { $0.focusStatus = focusStatusRule.toProtocol() }
    }
  }

  private enum CodingKeys: String, CodingKey {
    case shareTimeZone
    case appearInGlobalSearch
    case timeZoneRule
    case focusStatusRule
  }

  public required init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    shareTimeZone = try container.decodeIfPresent(Bool.self, forKey: .shareTimeZone) ?? true
    appearInGlobalSearch = try container.decodeIfPresent(Bool.self, forKey: .appearInGlobalSearch) ?? true
    timeZoneRule = try container.decodeIfPresent(PrivacyRuleValue.self, forKey: .timeZoneRule)
    focusStatusRule = try container.decodeIfPresent(PrivacyRuleValue.self, forKey: .focusStatusRule)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(shareTimeZone, forKey: .shareTimeZone)
    try container.encode(appearInGlobalSearch, forKey: .appearInGlobalSearch)
    try container.encodeIfPresent(timeZoneRule, forKey: .timeZoneRule)
    try container.encodeIfPresent(focusStatusRule, forKey: .focusStatusRule)
  }
}
