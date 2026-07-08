import AppKit
import Combine
import Foundation
import InlineKit
import InlineMacUI
import SwiftUI

enum AutoUpdateChannel: String, CaseIterable, Identifiable {
  case stable
  case beta

  var id: String { rawValue }

  var title: String {
    switch self {
    case .stable:
      return "Stable"
    case .beta:
      return "Beta"
    }
  }
}

enum AutoUpdateMode: String, CaseIterable, Identifiable {
  case off
  case check
  case download

  var id: String { rawValue }

  var title: String {
    switch self {
    case .off:
      return "Off"
    case .check:
      return "Check Automatically"
    case .download:
      return "Download Automatically"
    }
  }
}

enum AppAppearance: String, CaseIterable, Identifiable {
  case system
  case light
  case dark

  var id: String { rawValue }

  var title: String {
    switch self {
    case .system:
      return "System"
    case .light:
      return "Light"
    case .dark:
      return "Dark"
    }
  }

  var nsAppearance: NSAppearance? {
    switch self {
    case .system:
      return nil
    case .light:
      return NSAppearance(named: .aqua)
    case .dark:
      return NSAppearance(named: .darkAqua)
    }
  }
}

enum MacToolbarStyle: String, CaseIterable, Identifiable {
  case unified
  case unifiedCompact

  var id: String { rawValue }

  var title: String {
    switch self {
    case .unified:
      return "Unified"
    case .unifiedCompact:
      return "Compact"
    }
  }

  var nsToolbarStyle: NSWindow.ToolbarStyle {
    switch self {
    case .unified:
      return .unified
    case .unifiedCompact:
      return .unifiedCompact
    }
  }
}

enum SidebarCleanupInterval: String, CaseIterable, Identifiable {
  case twelveHours = "12h"
  case twentyFourHours = "24h"
  case twoDays = "2d"
  case fiveDays = "5d"
  case never

  static let defaultValue: Self = .twentyFourHours

  var id: String { rawValue }

  var title: String {
    switch self {
    case .twelveHours:
      return "12 hrs"
    case .twentyFourHours:
      return "24 hrs"
    case .twoDays:
      return "2 days"
    case .fiveDays:
      return "5 days"
    case .never:
      return "Off"
    }
  }

  var timeout: TimeInterval? {
    switch self {
    case .twelveHours:
      return 12 * 60 * 60
    case .twentyFourHours:
      return 24 * 60 * 60
    case .twoDays:
      return 2 * 24 * 60 * 60
    case .fiveDays:
      return 5 * 24 * 60 * 60
    case .never:
      return nil
    }
  }

  var detailText: String {
    switch self {
    case .twelveHours:
      return "Close chats i haven't opened or sent to in 12 hrs."
    case .twentyFourHours:
      return "Close chats i haven't opened or sent to in 24 hrs."
    case .twoDays:
      return "Close chats i haven't opened or sent to in 2 days."
    case .fiveDays:
      return "Close chats i haven't opened or sent to in 5 days."
    case .never:
      return "Don't close chats automatically."
    }
  }
}

enum MessageGestureAction: String, CaseIterable, Identifiable {
  case toggleAck
  case reply
  case toggleHeart
  case toggleThumbsUp
  case reactionsMenu

  static let defaultDoubleClick: Self = .toggleAck
  static let defaultHold: Self = .reactionsMenu

  var id: String { rawValue }

  var title: String {
    switch self {
    case .toggleAck:
      return "Toggle ACK"
    case .reply:
      return "Reply"
    case .toggleHeart:
      return "Toggle heart"
    case .toggleThumbsUp:
      return "Toggle thumbs up"
    case .reactionsMenu:
      return "Reactions menu"
    }
  }

  var reactionEmoji: String? {
    switch self {
    case .toggleAck:
      return "✔️"
    case .toggleHeart:
      return "❤️"
    case .toggleThumbsUp:
      return "👍"
    case .reply, .reactionsMenu:
      return nil
    }
  }
}

final class AppSettings: ObservableObject {
  static let shared = AppSettings()
  static let sidebarCleanupIntervalKey = "sidebarCleanupInterval"
  static let messageDoubleClickActionKey = "messageDoubleClickAction"
  static let messageHoldActionKey = "messageHoldAction"
  static let unreadBadgeStyleKey = "unreadBadgeStyle"

  // MARK: - General Settings

  @Published var sendsWithCmdEnter: Bool {
    didSet {
      UserDefaults.standard.set(sendsWithCmdEnter, forKey: "sendsWithCmdEnter")
    }
  }

  @Published var automaticSpellCorrection: Bool {
    didSet {
      UserDefaults.standard.set(automaticSpellCorrection, forKey: "automaticSpellCorrection")
    }
  }

  @Published var checkSpellingWhileTyping: Bool {
    didSet {
      UserDefaults.standard.set(checkSpellingWhileTyping, forKey: "checkSpellingWhileTyping")
    }
  }

  @Published var launchAtLogin: Bool {
    didSet {
      UserDefaults.standard.set(launchAtLogin, forKey: "launchAtLogin")
    }
  }

  // MARK: - Translation

  /// Global kill-switch for translation UI and related background work on macOS.
  @Published var translationUIEnabled: Bool {
    didSet {
      UserDefaults.standard.set(translationUIEnabled, forKey: "translationUIEnabled")
    }
  }

  // MARK: - Appearance

  @Published var appearance: AppAppearance {
    didSet {
      UserDefaults.standard.set(appearance.rawValue, forKey: "appAppearance")
    }
  }

  @Published var toolbarStyle: MacToolbarStyle {
    didSet {
      UserDefaults.standard.set(toolbarStyle.rawValue, forKey: "macToolbarStyle")
    }
  }

  @Published var messageRenderStyle: MessageRenderStyle {
    didSet {
      UserDefaults.standard.set(messageRenderStyle.rawValue, forKey: "messageRenderStyle")
    }
  }

  @Published var messageDoubleClickAction: MessageGestureAction {
    didSet {
      UserDefaults.standard.set(messageDoubleClickAction.rawValue, forKey: Self.messageDoubleClickActionKey)
    }
  }

  @Published var messageHoldAction: MessageGestureAction {
    didSet {
      UserDefaults.standard.set(messageHoldAction.rawValue, forKey: Self.messageHoldActionKey)
    }
  }

  // MARK: - Sidebar

  @Published var showSidebarMessagePreview: Bool {
    didSet {
      UserDefaults.standard.set(showSidebarMessagePreview, forKey: "showSidebarMessagePreview")
    }
  }

  @Published var includeSpaceChatsInHomeSidebar: Bool {
    didSet {
      UserDefaults.standard.set(includeSpaceChatsInHomeSidebar, forKey: "includeSpaceChatsInHomeSidebar")
    }
  }

  @Published var sidebarCleanupInterval: SidebarCleanupInterval {
    didSet {
      UserDefaults.standard.set(sidebarCleanupInterval.rawValue, forKey: Self.sidebarCleanupIntervalKey)
    }
  }

  // MARK: - Notification Settings

  @Published var disableNotificationSound: Bool {
    didSet {
      UserDefaults.standard.set(disableNotificationSound, forKey: "disableNotificationSound")
    }
  }

  @Published var showDockBadgeUnreadDMs: Bool {
    didSet {
      UserDefaults.standard.set(showDockBadgeUnreadDMs, forKey: "showDockBadgeUnreadDMs")
    }
  }

  @Published var unreadBadgeStyle: UnreadBadgeStyle {
    didSet {
      UserDefaults.standard.set(unreadBadgeStyle.rawValue, forKey: Self.unreadBadgeStyleKey)
    }
  }

  // MARK: - Experimental Settings

  @Published var showMainTabStrip: Bool {
    didSet {
      UserDefaults.standard.set(showMainTabStrip, forKey: "showMainTabStrip")
    }
  }

  @Published var sidebarAsInbox: Bool {
    didSet {
      UserDefaults.standard.set(sidebarAsInbox, forKey: ExperimentalFeatureFlags.sidebarAsInboxKey)
    }
  }

  // MARK: - Updates

  @Published var autoUpdateChannel: AutoUpdateChannel {
    didSet {
      UserDefaults.standard.set(autoUpdateChannel.rawValue, forKey: "autoUpdateChannel")
    }
  }

  @Published var autoUpdateMode: AutoUpdateMode {
    didSet {
      UserDefaults.standard.set(autoUpdateMode.rawValue, forKey: "autoUpdateMode")
    }
  }

  private init() {
    sendsWithCmdEnter = UserDefaults.standard.bool(forKey: "sendsWithCmdEnter")
    automaticSpellCorrection = UserDefaults.standard.object(forKey: "automaticSpellCorrection") as? Bool ?? true
    checkSpellingWhileTyping = UserDefaults.standard.object(forKey: "checkSpellingWhileTyping") as? Bool ?? true
    launchAtLogin = UserDefaults.standard.bool(forKey: "launchAtLogin")
    translationUIEnabled = UserDefaults.standard.object(forKey: "translationUIEnabled") as? Bool ?? true

    if let storedAppearance = UserDefaults.standard.string(forKey: "appAppearance"),
       let appearanceValue = AppAppearance(rawValue: storedAppearance) {
      appearance = appearanceValue
    } else {
      appearance = .system
    }

    if let storedToolbarStyle = UserDefaults.standard.string(forKey: "macToolbarStyle"),
       let toolbarStyleValue = MacToolbarStyle(rawValue: storedToolbarStyle) {
      toolbarStyle = toolbarStyleValue
    } else {
      toolbarStyle = .unified
    }

    if let storedMessageRenderStyle = UserDefaults.standard.string(forKey: "messageRenderStyle"),
       let style = MessageRenderStyle(rawValue: storedMessageRenderStyle) {
      messageRenderStyle = style
    } else {
      messageRenderStyle = .bubble
    }

    if let storedDoubleClickAction = UserDefaults.standard.string(forKey: Self.messageDoubleClickActionKey),
       let action = MessageGestureAction(rawValue: storedDoubleClickAction) {
      messageDoubleClickAction = action
    } else {
      messageDoubleClickAction = .defaultDoubleClick
    }

    if let storedHoldAction = UserDefaults.standard.string(forKey: Self.messageHoldActionKey),
       let action = MessageGestureAction(rawValue: storedHoldAction) {
      messageHoldAction = action
    } else {
      messageHoldAction = .defaultHold
    }

    if let storedShowPreview = UserDefaults.standard.object(forKey: "showSidebarMessagePreview") as? Bool {
      showSidebarMessagePreview = storedShowPreview
    } else {
      showSidebarMessagePreview = true
    }
    includeSpaceChatsInHomeSidebar =
      UserDefaults.standard.object(forKey: "includeSpaceChatsInHomeSidebar") as? Bool ?? true
    if let storedCleanupInterval = UserDefaults.standard.string(forKey: Self.sidebarCleanupIntervalKey),
       let cleanupInterval = SidebarCleanupInterval(rawValue: storedCleanupInterval) {
      sidebarCleanupInterval = cleanupInterval
    } else {
      sidebarCleanupInterval = .defaultValue
    }
    disableNotificationSound = UserDefaults.standard.bool(forKey: "disableNotificationSound")
    showDockBadgeUnreadDMs = UserDefaults.standard.object(forKey: "showDockBadgeUnreadDMs") as? Bool ?? true
    if let storedUnreadBadgeStyle = UserDefaults.standard.string(forKey: Self.unreadBadgeStyleKey),
       let badgeStyle = UnreadBadgeStyle(rawValue: storedUnreadBadgeStyle) {
      unreadBadgeStyle = badgeStyle
    } else {
      unreadBadgeStyle = .defaultValue
    }
    showMainTabStrip = UserDefaults.standard.object(forKey: "showMainTabStrip") as? Bool ?? false
    sidebarAsInbox = UserDefaults.standard.bool(forKey: ExperimentalFeatureFlags.sidebarAsInboxKey)
    if let storedChannel = UserDefaults.standard.string(forKey: "autoUpdateChannel"),
       !storedChannel.isEmpty,
       let channel = AutoUpdateChannel(rawValue: storedChannel) {
      autoUpdateChannel = channel
    } else if let inferred = AppSettings.inferUpdateChannelFromBundle() {
      autoUpdateChannel = inferred
    } else {
      autoUpdateChannel = .stable
    }

    if let storedMode = UserDefaults.standard.string(forKey: "autoUpdateMode"),
       !storedMode.isEmpty,
       let mode = AutoUpdateMode(rawValue: storedMode) {
      autoUpdateMode = mode
    } else {
      autoUpdateMode = .download
    }
  }

  private static func inferUpdateChannelFromBundle() -> AutoUpdateChannel? {
    guard let feedUrl = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String else {
      return nil
    }
    if feedUrl.contains("/beta/") {
      return .beta
    }
    if feedUrl.contains("/stable/") {
      return .stable
    }
    return nil
  }
}

// MARK: - UserDefaults Property Wrapper

@propertyWrapper
struct UserDefault<T> {
  let key: String
  let defaultValue: T

  var wrappedValue: T {
    get {
      UserDefaults.standard.object(forKey: key) as? T ?? defaultValue
    }
    set {
      UserDefaults.standard.set(newValue, forKey: key)
    }
  }
}
