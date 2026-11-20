import AppKit
import Auth
import Combine
import Foundation
import GRDB
import InlineKit
import InlineMacUI
import InlineUI
import MacTheme
import SwiftUI
import TextProcessing

enum AppAppearance: String, CaseIterable, Identifiable {
  case system
  case light
  case dark

  static let pickerOrder: [Self] = [.light, .dark, .system]

  var id: String { rawValue }

  var title: String {
    switch self {
    case .system:
      return "Auto"
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

  static let defaultValue: Self = .never

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
      return "Close chats I haven't opened or sent to in 12 hrs."
    case .twentyFourHours:
      return "Close chats I haven't opened or sent to in 24 hrs."
    case .twoDays:
      return "Close chats I haven't opened or sent to in 2 days."
    case .fiveDays:
      return "Close chats I haven't opened or sent to in 5 days."
    case .never:
      return "Don't close chats automatically."
    }
  }
}

enum SidebarActiveRowStyle: String, CaseIterable, Identifiable {
  case solid
  case glass
  case gray

  static let defaultValue: Self = .gray

  var id: String { rawValue }

  var title: String {
    switch self {
    case .solid:
      return "Solid"
    case .glass:
      return "Glass"
    case .gray:
      return "Gray"
    }
  }
}

final class AppSettings: ObservableObject {
  static let shared = AppSettings()
  static let sidebarCleanupIntervalKey = "sidebarCleanupInterval"
  static let sidebarItemSizeKey = "sidebarItemSize"
  static let sidebarActiveRowStyleKey = "sidebarActiveRowStyle"
  static let sidebarModeKey = "sidebarMode"
  static let showGridInSidebarKey = "showGridInSidebar"
  static let richContentRendererEnabledKey = "experimental.richContentRendererEnabled"
  static let richTextInlineMathEnabledKey = "experimental.richTextInlineMathEnabled"
  static let messageWidgetsEnabledKey = "experimental.messageWidgetsEnabled"
  static let stableChatRouteEnabledKey = "experimental.stableChatRouteEnabled"
  static let coreTextMessageTextEnabledKey = CoreTextMessageText.defaultsKey
  static let sidebarSortKey = "sidebarSort"
  static let messageDoubleClickActionKey = "messageDoubleClickAction"
  static let messageHoldActionKey = "messageHoldAction"
  static let openReplyThreadsInSidePaneKey = "openReplyThreadsInSidePane"
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

  @Published var appTheme: AppThemePreset {
    didSet {
      guard appTheme != oldValue else { return }
      UserDefaults.standard.set(appTheme.rawValue, forKey: ThemePreference.selectedPresetKey)
      publishThemeChange()
    }
  }

  @Published var sidebarGlassAndTintEnabled: Bool {
    didSet {
      guard sidebarGlassAndTintEnabled != oldValue else { return }
      UserDefaults.standard.set(
        sidebarGlassAndTintEnabled,
        forKey: ThemePreference.sidebarGlassAndTintEnabledKey
      )
      publishThemeChange()
    }
  }

  @Published private(set) var themeRevision = 0

  @Published var toolbarStyle: MacToolbarStyle {
    didSet {
      UserDefaults.standard.set(toolbarStyle.rawValue, forKey: "macToolbarStyle")
    }
  }

  var usesCompactToolbar: Bool {
    get { toolbarStyle == .unifiedCompact }
    set { toolbarStyle = newValue ? .unifiedCompact : .unified }
  }

  func themePaletteDidChange() {
    publishThemeChange()
  }

  private func publishThemeChange() {
    themeRevision &+= 1
  }

  @Published var messageRenderStyle: MessageRenderStyle {
    didSet {
      UserDefaults.standard.set(messageRenderStyle.rawValue, forKey: "messageRenderStyle")
    }
  }

  @Published var centeredChats: Bool {
    didSet {
      UserDefaults.standard.set(centeredChats, forKey: "centeredChats")
    }
  }

  // MARK: - Chat typography

  // Stored as strings so hand-edited defaults (fallback family lists, fractional
  // sizes) keep working. Every change applies live through `ChatTypography.apply`.

  @Published var chatFontFamilies: String {
    didSet {
      Self.persistOptionalString(chatFontFamilies, forKey: ChatTypography.fontFamiliesDefaultsKey)
      applyChatTypography()
    }
  }

  @Published var chatFontSize: String {
    didSet {
      Self.persistOptionalString(chatFontSize, forKey: ChatTypography.fontSizeDefaultsKey)
      applyChatTypography()
    }
  }

  @Published var chatLineHeight: String {
    didSet {
      Self.persistOptionalString(chatLineHeight, forKey: ChatTypography.lineHeightDefaultsKey)
      applyChatTypography()
    }
  }

  @Published var chatCodeFontFamily: String {
    didSet {
      Self.persistOptionalString(chatCodeFontFamily, forKey: ChatTypography.codeFontFamilyDefaultsKey)
      applyChatTypography()
    }
  }

  var chatTypographySource: ChatTypography.Source {
    ChatTypography.Source(
      fontFamilies: chatFontFamilies,
      fontSize: chatFontSize,
      lineHeight: chatLineHeight,
      codeFontFamily: chatCodeFontFamily
    )
  }

  var hasChatTypographyOverrides: Bool {
    !chatFontFamilies.isEmpty || !chatFontSize.isEmpty || !chatLineHeight.isEmpty
      || !chatCodeFontFamily.isEmpty
  }

  /// The main message font: empty for System, a design token, or a family name.
  /// Setting it keeps any fallback fonts.
  var chatPrimaryFontFamily: String {
    get {
      let primary = ChatTypography.familyList(chatFontFamilies).first ?? ""
      return primary.caseInsensitiveCompare(ChatTypography.SystemDesign.standard.token) == .orderedSame ? "" : primary
    }
    set { setChatFontFamilies(primary: newValue, fallbacks: chatFallbackFontFamilies) }
  }

  /// Fonts for characters the main font lacks (other scripts, symbols), in order.
  var chatFallbackFontFamilies: [String] {
    Array(ChatTypography.familyList(chatFontFamilies).dropFirst())
  }

  /// The first fallback font; empty for none. Setting it keeps any further fallbacks.
  var chatFallbackFontFamily: String {
    get { chatFallbackFontFamilies.first ?? "" }
    set {
      let rest = chatFallbackFontFamilies.dropFirst()
      setChatFontFamilies(
        primary: chatPrimaryFontFamily,
        fallbacks: (newValue.isEmpty ? [] : [newValue]) + rest
      )
    }
  }

  private func setChatFontFamilies(primary: String, fallbacks: [String]) {
    let fallbacks = fallbacks.filter { $0.caseInsensitiveCompare(primary) != .orderedSame }
    if fallbacks.isEmpty {
      chatFontFamilies = primary
    } else {
      let head = primary.isEmpty ? ChatTypography.SystemDesign.standard.token : primary
      chatFontFamilies = ChatTypography.familyString([head] + fallbacks)
    }
  }

  /// Message text size in points; setting the default size clears the override.
  var chatPointSize: CGFloat {
    get { ChatTypography.current.pointSize }
    set {
      guard newValue.isFinite else { return }
      let size = min(max(newValue, ChatTypography.minimumPointSize), ChatTypography.maximumPointSize)
      chatFontSize = size == ChatTypography.defaultPointSize ? "" : ChatTypography.format(size)
    }
  }

  var canIncreaseChatTextSize: Bool {
    ChatTypography.nextLargerSize(than: chatPointSize) != nil
  }

  var canDecreaseChatTextSize: Bool {
    ChatTypography.nextSmallerSize(than: chatPointSize) != nil
  }

  var isChatTextSizeDefault: Bool {
    chatPointSize == ChatTypography.defaultPointSize
  }

  func increaseChatTextSize() {
    guard let size = ChatTypography.nextLargerSize(than: chatPointSize) else { NSSound.beep(); return }
    chatPointSize = size
  }

  func decreaseChatTextSize() {
    guard let size = ChatTypography.nextSmallerSize(than: chatPointSize) else { NSSound.beep(); return }
    chatPointSize = size
  }

  func resetChatTextSize() {
    chatFontSize = ""
  }

  /// Line height as a multiple of the font size; the default clears the override.
  var chatLineHeightValue: CGFloat {
    get { ChatTypography.current.lineHeight }
    set {
      guard newValue.isFinite else { return }
      let value = min(max(newValue, ChatTypography.minimumLineHeight), ChatTypography.maximumLineHeight)
      chatLineHeight = value == ChatTypography.defaultLineHeight ? "" : ChatTypography.format(value)
    }
  }

  func resetChatTypography() {
    resetChatTextStyle()
    chatFontSize = ""
  }

  /// Fonts and spacing back to defaults; the text size stays.
  func resetChatTextStyle() {
    chatFontFamilies = ""
    chatLineHeight = ""
    chatCodeFontFamily = ""
  }

  var hasChatTextStyleOverrides: Bool {
    !chatFontFamilies.isEmpty || !chatLineHeight.isEmpty || !chatCodeFontFamily.isEmpty
  }

  private func applyChatTypography() {
    ChatTypography.apply(chatTypographySource)
  }

  @Published var preferredEmojiSkinTone: EmojiSkinTone {
    didSet {
      EmojiSkinTonePreferenceStore.set(preferredEmojiSkinTone)
    }
  }

  @Published var unreadBadgeStyle: UnreadBadgeStyle {
    didSet {
      UserDefaults.standard.set(unreadBadgeStyle.rawValue, forKey: Self.unreadBadgeStyleKey)
    }
  }

  @MainActor var messageDoubleClickAction: MessageGestureAction {
    INUserSettings.current.messageGestures.doubleTapAction
  }

  @MainActor var messageHoldAction: MessageGestureAction {
    INUserSettings.current.messageGestures.holdAction
  }

  @MainActor var messageSwipeToReplyDirection: MessageSwipeToReplyDirection {
    INUserSettings.current.messageGestures.swipeToReplyDirection
  }

  @Published var openReplyThreadsInSidePane: Bool {
    didSet {
      UserDefaults.standard.set(openReplyThreadsInSidePane, forKey: Self.openReplyThreadsInSidePaneKey)
    }
  }

  // MARK: - Sidebar

  @Published var sidebarItemSize: SidebarItemSize {
    didSet {
      UserDefaults.standard.set(sidebarItemSize.rawValue, forKey: Self.sidebarItemSizeKey)
    }
  }

  @Published var sidebarActiveRowStyle: SidebarActiveRowStyle {
    didSet {
      guard sidebarActiveRowStyle != oldValue else { return }
      UserDefaults.standard.set(sidebarActiveRowStyle.rawValue, forKey: Self.sidebarActiveRowStyleKey)
      publishThemeChange()
    }
  }

  var showSidebarMessagePreview: Bool {
    get { sidebarItemSize != .compact }
    set { sidebarItemSize = newValue ? .standard : .compact }
  }

  @Published var sidebarSort: SidebarSortMode {
    didSet {
      UserDefaults.standard.set(sidebarSort.rawValue, forKey: Self.sidebarSortKey)
    }
  }

  @Published var sidebarCleanupInterval: SidebarCleanupInterval {
    didSet {
      UserDefaults.standard.set(sidebarCleanupInterval.rawValue, forKey: Self.sidebarCleanupIntervalKey)
    }
  }

  @Published var sidebarMode: SidebarMode {
    didSet {
      sidebarModeNeedsAccountMigration = false
      UserDefaults.standard.set(sidebarMode.rawValue, forKey: Self.sidebarModeKey)
    }
  }

  @Published var showGridInSidebar: Bool {
    didSet {
      UserDefaults.standard.set(showGridInSidebar, forKey: Self.showGridInSidebarKey)
    }
  }

  /// Compatibility boundary for call sites that only care about Inbox
  /// behavior and for the one-time legacy preference migration.
  var sidebarAsInbox: Bool {
    get { sidebarMode == .inbox }
    set { sidebarMode = newValue ? .inbox : .allChats }
  }

  private var sidebarModeNeedsAccountMigration = false

  func resolveSidebarModeForAccount(createdAt: Date) {
    guard sidebarModeNeedsAccountMigration else { return }
    sidebarMode = SidebarPreferenceMigration.inboxEnabled(
      storedModeIsInbox: nil,
      legacyInboxEnabled: nil,
      accountCreatedAt: createdAt
    ) ? .inbox : .allChats
  }

  func resolveSidebarModeForCurrentAccount() {
    guard sidebarModeNeedsAccountMigration,
          let createdAt = Self.currentAccountCreatedAt() else { return }
    resolveSidebarModeForAccount(createdAt: createdAt)
  }

  // MARK: - Notification Settings

  @Published var disableNotificationSound: Bool {
    didSet {
      UserDefaults.standard.set(disableNotificationSound, forKey: "disableNotificationSound")
    }
  }

  var notificationSoundEnabled: Bool {
    get { !disableNotificationSound }
    set { disableNotificationSound = !newValue }
  }

  @Published var showDockBadgeUnreadDMs: Bool {
    didSet {
      UserDefaults.standard.set(showDockBadgeUnreadDMs, forKey: "showDockBadgeUnreadDMs")
    }
  }

  // MARK: - Experimental Settings

  @Published var richContentRendererEnabled: Bool {
    didSet {
      UserDefaults.standard.set(
        richContentRendererEnabled,
        forKey: Self.richContentRendererEnabledKey
      )
    }
  }

  /// Live HTML widgets that bots send in messages. Off until the host is ready.
  @Published var messageWidgetsEnabled: Bool {
    didSet {
      UserDefaults.standard.set(messageWidgetsEnabled, forKey: Self.messageWidgetsEnabledKey)
    }
  }

  /// Keeps one chat route (toolbar and AppKit chat host) alive across chat switches instead of
  /// rebuilding it per chat. Off until it has been checked against the per-chat route.
  @Published var stableChatRouteEnabled: Bool {
    didSet {
      UserDefaults.standard.set(stableChatRouteEnabled, forKey: Self.stableChatRouteEnabledKey)
    }
  }

  /// Draws plain message text with Inline's Core Text renderer instead of NSTextView. Rich
  /// messages keep NSTextView. Off until it reaches parity.
  @Published var coreTextMessageTextEnabled: Bool {
    didSet {
      UserDefaults.standard.set(coreTextMessageTextEnabled, forKey: Self.coreTextMessageTextEnabledKey)
      // Text sizes come from the renderer that draws them.
      MessageSizeCalculator.shared.invalidateCache()
    }
  }

  @Published var richTextInlineMathEnabled: Bool {
    didSet {
      UserDefaults.standard.set(
        richTextInlineMathEnabled,
        forKey: Self.richTextInlineMathEnabledKey
      )
    }
  }

  private init() {
    let persistentDefaults = Bundle.main.bundleIdentifier.flatMap {
      UserDefaults.standard.persistentDomain(forName: $0)
    }

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

    appTheme = ThemePreference.selectedPreset()
    sidebarGlassAndTintEnabled = ThemePreference.sidebarGlassAndTintEnabled()

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
    centeredChats = UserDefaults.standard.object(forKey: "centeredChats") as? Bool ?? true
    let chatTypographySource = ChatTypography.storedSource()
    chatFontFamilies = chatTypographySource.fontFamilies
    chatFontSize = chatTypographySource.fontSize
    chatLineHeight = chatTypographySource.lineHeight
    chatCodeFontFamily = chatTypographySource.codeFontFamily

    preferredEmojiSkinTone = EmojiSkinTonePreferenceStore.current()

    openReplyThreadsInSidePane =
      UserDefaults.standard.object(forKey: Self.openReplyThreadsInSidePaneKey) as? Bool ?? false

    if let storedItemSize = persistentDefaults?[Self.sidebarItemSizeKey] as? String,
       let itemSize = SidebarItemSize(rawValue: storedItemSize) {
      sidebarItemSize = itemSize
      UserDefaults.standard.set(itemSize.rawValue, forKey: Self.sidebarItemSizeKey)
    } else {
      let storedShowPreview = persistentDefaults?["showSidebarMessagePreview"] as? Bool ?? false
      let itemSize: SidebarItemSize = storedShowPreview ? .standard : .compact
      sidebarItemSize = itemSize
      UserDefaults.standard.set(itemSize.rawValue, forKey: Self.sidebarItemSizeKey)
    }
    if let storedActiveRowStyle = UserDefaults.standard.string(forKey: Self.sidebarActiveRowStyleKey),
       let activeRowStyle = SidebarActiveRowStyle(rawValue: storedActiveRowStyle) {
      sidebarActiveRowStyle = activeRowStyle
    } else {
      sidebarActiveRowStyle = .defaultValue
    }
    if let storedSidebarSort = UserDefaults.standard.string(forKey: Self.sidebarSortKey),
       let sort = SidebarSortMode(rawValue: storedSidebarSort) {
      sidebarSort = sort
    } else {
      sidebarSort = .openedOrder
    }
    if let storedCleanupInterval = persistentDefaults?[Self.sidebarCleanupIntervalKey] as? String,
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
    richContentRendererEnabled = UserDefaults.standard.object(
      forKey: Self.richContentRendererEnabledKey
    ) as? Bool ?? true
    messageWidgetsEnabled = UserDefaults.standard.object(forKey: Self.messageWidgetsEnabledKey) as? Bool ?? false
    stableChatRouteEnabled = UserDefaults.standard.object(forKey: Self.stableChatRouteEnabledKey) as? Bool ?? false
    coreTextMessageTextEnabled = UserDefaults.standard.object(forKey: Self.coreTextMessageTextEnabledKey) as? Bool ?? false
    richTextInlineMathEnabled = UserDefaults.standard.object(
      forKey: Self.richTextInlineMathEnabledKey
    ) as? Bool ?? false
    let storedMode = (persistentDefaults?[Self.sidebarModeKey] as? String)
      .flatMap(SidebarMode.init(rawValue:))
    let legacyInbox = persistentDefaults?[ExperimentalFeatureFlags.sidebarAsInboxKey] as? Bool
    let accountCreatedAt = Self.currentAccountCreatedAt()
    sidebarModeNeedsAccountMigration = storedMode == nil
      && legacyInbox == nil
      && accountCreatedAt == nil
    let inboxEnabled = SidebarPreferenceMigration.inboxEnabled(
      storedModeIsInbox: storedMode.map { $0 == .inbox },
      legacyInboxEnabled: legacyInbox,
      accountCreatedAt: accountCreatedAt
    )
    sidebarMode = inboxEnabled ? .inbox : .allChats
    showGridInSidebar = persistentDefaults?[Self.showGridInSidebarKey] as? Bool ?? true
    if sidebarModeNeedsAccountMigration == false {
      UserDefaults.standard.set(sidebarMode.rawValue, forKey: Self.sidebarModeKey)
    }
  }

  private static func persistOptionalString(_ value: String, forKey key: String) {
    if value.isEmpty {
      UserDefaults.standard.removeObject(forKey: key)
    } else {
      UserDefaults.standard.set(value, forKey: key)
    }
  }

  private static func currentAccountCreatedAt() -> Date? {
    guard let userID = Auth.getCurrentUserId(), AppDatabase.shared.isPersistent else {
      return nil
    }
    do {
      return try AppDatabase.shared.reader.read { db in
        try User.fetchOne(db, id: userID)?.date
      }
    } catch {
      return nil
    }
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
