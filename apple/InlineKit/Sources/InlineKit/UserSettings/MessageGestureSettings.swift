import Combine
import Foundation
import InlineProtocol

public struct MessageGestureValues: Codable, Equatable, Sendable {
  public var doubleTapAction: MessageGestureAction = .defaultDoubleClick
  public var holdAction: MessageGestureAction = .defaultHold
  public var swipeToReplyDirection: MessageSwipeToReplyDirection = .defaultValue

  public init() {}

  init(_ settings: InlineProtocol.MessageGestureSettings) {
    doubleTapAction = MessageGestureAction(rawValue: settings.doubleTapAction) ?? .defaultDoubleClick
    holdAction = MessageGestureAction(rawValue: settings.holdAction) ?? .defaultHold
    swipeToReplyDirection = MessageSwipeToReplyDirection(rawValue: settings.swipeToReplyDirection) ?? .defaultValue
  }

  func toProtocol() -> InlineProtocol.MessageGestureSettings {
    .with {
      $0.doubleTapAction = doubleTapAction.rawValue
      $0.holdAction = holdAction.rawValue
      $0.swipeToReplyDirection = swipeToReplyDirection.rawValue
    }
  }
}

/// The account value keeps refreshing even when this device uses a local override.
/// Rejoining sync adopts that account value instead of publishing the override.
@MainActor
public final class MessageGestureSettingsManager: ObservableObject {
  @Published var accountValues: MessageGestureValues?
  @Published private var localValues = MessageGestureValues()
  @Published private var usesAccountValues = true
  private let defaults: UserDefaults
  private let legacyDefaults: UserDefaults
  private var userID: Int64?

  init(defaults: UserDefaults, legacyDefaults: UserDefaults = .standard) {
    self.defaults = defaults
    self.legacyDefaults = legacyDefaults
  }

  public var syncEnabled: Bool {
    get { usesAccountValues }
    set {
      guard newValue != usesAccountValues else { return }
      if !newValue { localValues = effectiveValues }
      usesAccountValues = newValue
      persistLocalPreferences()
    }
  }

  public var doubleTapAction: MessageGestureAction {
    get { effectiveValues.doubleTapAction }
    set { edit { $0.doubleTapAction = newValue } }
  }

  public var holdAction: MessageGestureAction {
    get { effectiveValues.holdAction }
    set { edit { $0.holdAction = newValue } }
  }

  public var swipeToReplyDirection: MessageSwipeToReplyDirection {
    get { effectiveValues.swipeToReplyDirection }
    set { edit { $0.swipeToReplyDirection = newValue } }
  }

  private var effectiveValues: MessageGestureValues {
    usesAccountValues ? accountValues ?? localValues : localValues
  }

  private func edit(_ change: (inout MessageGestureValues) -> Void) {
    var values = effectiveValues
    change(&values)
    guard values != effectiveValues else { return }
    if usesAccountValues {
      accountValues = values
    } else {
      localValues = values
      persistLocalPreferences()
    }
  }

  func configure(for userID: Int64?) {
    self.userID = userID
    accountValues = nil
    localValues = MessageGestureValues()
    usesAccountValues = true
    guard let userID else { return }
    let key = "messageGestures.device.\(userID)"
    usesAccountValues = defaults.object(forKey: "\(key).sync") as? Bool ?? true
    if let data = defaults.data(forKey: key),
       let saved = try? JSONDecoder().decode(MessageGestureValues.self, from: data) {
      localValues = saved
    } else {
      // Claim device-wide legacy preferences for one account only.
      let ownerKey = "messageGestures.legacyOwner"
      let owner = defaults.string(forKey: ownerKey)
      if owner == nil || owner == String(userID) {
        defaults.set(String(userID), forKey: ownerKey)
        let doubleTap = legacyDefaults.string(forKey: "messageDoubleTapAction")
          ?? legacyDefaults.string(forKey: "messageDoubleClickAction")
        localValues.doubleTapAction = doubleTap.flatMap(MessageGestureAction.init(rawValue:)) ?? .defaultDoubleClick
        localValues.holdAction = legacyDefaults.string(forKey: "messageHoldAction")
          .flatMap(MessageGestureAction.init(rawValue:)) ?? .defaultHold
        localValues.swipeToReplyDirection = .stored(in: legacyDefaults)
      }
      persistLocalPreferences()
    }
  }

  private func persistLocalPreferences() {
    guard let userID else { return }
    let key = "messageGestures.device.\(userID)"
    defaults.set(usesAccountValues, forKey: "\(key).sync")
    if let data = try? JSONEncoder().encode(localValues) {
      defaults.set(data, forKey: key)
    }
  }
}
