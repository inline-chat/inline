import Foundation
import InlineUI

/// Static index of searchable settings rows. Rows read their title from here, so search and UI can't drift.
enum SettingsSearchItem: String, CaseIterable, Identifiable, Hashable, Sendable {
  // Account
  case profile
  case username
  case email
  case phone
  case technicalDetails
  case signOut

  // General
  case launchAtLogin
  case automaticSpellCorrection
  case checkSpellingWhileTyping
  case shortenSupportedLinks
  case sendMessages
  case syncMessageGestures
  case doubleClick
  case hold
  case swipeToReply
  case translationControls
  case openReplyThreadsInSidePane
  case openChatsCleanup

  // Appearance
  case appearance
  case theme
  case sidebarItemSize
  case chatIcon
  case sidebarTint
  case messageStyle
  case preferredSkinTone
  case unreadBadgeStyle
  case compactToolbar
  case centeredChats
  case fonts
  case fontSize

  // Audio and Video
  case inputDevice
  case outputDevice
  case autoUnmuteOnJoin
  case autoMuteWhenAlone

  // Notifications
  case dockBadge
  case notificationSounds

  // Privacy
  case appearInGlobalSearch
  case shareTimeZone

  // Data & Storage
  case autoDownloadMedia
  case autoDownloadFiles
  case autoDownloadVoiceMessages

  // Connectors
  case connectors

  // Hotkeys
  case focusInlineHotkey
  case gridMicrophoneHotkey

  // Bots
  case agentSetup
  case createBot
  case yourBots
  case skilledAgents

  // Active Sessions
  case signedInDevices

#if SPARKLE
  // Updates
  case softwareUpdate
  case automaticUpdates
  case updateChannel
#endif

  // Experimental
  case agentActivity
  case newThreadAgentPicker
  case richContentRenderer
  case inlineMathAttachments
  case richMessageMultiBlockSelection
  case richCopyMarkdownEditing
  case selectMultipleMessages
  case quickForward
  case gridTranscription
  case fileBrowser
  case nativeFileDownloads

  // Debug
  case syncEngine
  case appPermissions
  case connectionSecurity
  case macDevtools
  case onboarding
  case playground
  case appCache
  case mediaCache
  case dismissedPopovers
  case themeWorkshop
  case localDatabase

  var id: String { rawValue }

  var category: SettingsCategory {
    switch self {
    case .profile, .username, .email, .phone, .technicalDetails, .signOut:
      .account
    case .launchAtLogin, .automaticSpellCorrection, .checkSpellingWhileTyping, .shortenSupportedLinks,
         .sendMessages, .syncMessageGestures, .doubleClick, .hold, .swipeToReply, .translationControls,
         .openReplyThreadsInSidePane, .openChatsCleanup:
      .general
    case .appearance, .theme, .sidebarItemSize, .chatIcon, .sidebarTint, .messageStyle, .preferredSkinTone,
         .unreadBadgeStyle, .compactToolbar, .centeredChats, .fonts, .fontSize:
      .appearance
    case .inputDevice, .outputDevice, .autoUnmuteOnJoin, .autoMuteWhenAlone:
      .audioAndVideo
    case .dockBadge, .notificationSounds:
      .notifications
    case .appearInGlobalSearch, .shareTimeZone:
      .privacy
    case .autoDownloadMedia, .autoDownloadFiles, .autoDownloadVoiceMessages:
      .dataStorage
    case .connectors:
      .connectors
    case .focusInlineHotkey, .gridMicrophoneHotkey:
      .hotkeys
    case .agentSetup, .createBot, .yourBots, .skilledAgents:
      .bots
    case .signedInDevices:
      .activeSessions
#if SPARKLE
    case .softwareUpdate, .automaticUpdates, .updateChannel:
      .updates
#endif
    case .agentActivity, .newThreadAgentPicker, .richContentRenderer, .inlineMathAttachments,
         .richMessageMultiBlockSelection, .richCopyMarkdownEditing, .selectMultipleMessages, .quickForward,
         .gridTranscription, .fileBrowser, .nativeFileDownloads:
      .experimental
    case .syncEngine, .appPermissions, .connectionSecurity, .macDevtools, .onboarding, .playground,
         .appCache, .mediaCache, .dismissedPopovers, .themeWorkshop, .localDatabase:
      .debug
    }
  }

  var title: LocalizedStringResource {
    switch self {
    case .profile: "Profile"
    case .username: "Username"
    case .email: "Email"
    case .phone: "Phone"
    case .technicalDetails: "Technical Details"
    case .signOut: "This Mac"
    case .launchAtLogin: "Launch at Login"
    case .automaticSpellCorrection: "Automatic Spell Correction"
    case .checkSpellingWhileTyping: "Check Spelling While Typing"
    case .shortenSupportedLinks: "Shorten Supported Links"
    case .sendMessages: "Send Messages"
    case .syncMessageGestures: "Sync Message Gestures"
    case .doubleClick: "Double-click"
    case .hold: "Hold"
    case .swipeToReply: "Swipe to Reply"
    case .translationControls: "Translation Controls"
    case .openReplyThreadsInSidePane: "Open Reply Threads in Side Pane"
    case .openChatsCleanup: "Open Chats Cleanup"
    case .appearance: "Appearance"
    case .theme: "Theme"
    case .sidebarItemSize: "Item Size"
    case .chatIcon: "Chat Icon"
    case .sidebarTint: "Sidebar Tint"
    case .messageStyle: "Message Style"
    case .preferredSkinTone: "Preferred Skin Tone"
    case .unreadBadgeStyle: "Unread Badge Style"
    case .compactToolbar: "Compact Toolbar"
    case .centeredChats: "Centered Chats"
    case .fonts: "Fonts"
    case .fontSize: "Size"
    case .inputDevice: "Input Device"
    case .outputDevice: "Output Device"
    case .autoUnmuteOnJoin: "Auto-Unmute on Join"
    case .autoMuteWhenAlone: "Auto-Mute When Alone"
    case .dockBadge: "Dock Badge"
    case .notificationSounds: "Notification Sounds"
    case .appearInGlobalSearch: "Appear in Global Search"
    case .shareTimeZone: "Share Time Zone"
    case .autoDownloadMedia: "Media"
    case .autoDownloadFiles: "Files"
    case .autoDownloadVoiceMessages: "Voice Messages"
    case .connectors: "Connectors"
    case .focusInlineHotkey: "Focus Inline"
    case .gridMicrophoneHotkey: "Grid Microphone"
    case .agentSetup: "Agent Setup"
    case .createBot: "Create Bot"
    case .yourBots: "Your Bots"
    case .skilledAgents: "Skilled Agents"
    case .signedInDevices: "Signed-In Devices"
#if SPARKLE
    case .softwareUpdate: "Software Update"
    case .automaticUpdates: "Automatic Updates"
    case .updateChannel: "Update Channel"
#endif
    case .agentActivity: "Agent Activity"
    case .newThreadAgentPicker: "New Thread Agent Picker"
    case .richContentRenderer: "Rich Content Renderer"
    case .inlineMathAttachments: "Inline Math Attachments"
    case .richMessageMultiBlockSelection: "Rich Message Multi-Block Selection"
    case .richCopyMarkdownEditing: "Rich Copy & Markdown Editing"
    case .selectMultipleMessages: "Select Multiple Messages"
    case .quickForward: "Quick Forward"
    case .gridTranscription: "Grid Transcription"
    case .fileBrowser: "File Browser"
    case .nativeFileDownloads: "Native File Downloads"
    case .syncEngine: "Sync Engine"
    case .appPermissions: "App Permissions"
    case .connectionSecurity: "Connection Security"
    case .macDevtools: "MacDevtools"
    case .onboarding: "Onboarding"
    case .playground: "Playground"
    case .appCache: "App Cache"
    case .mediaCache: "Media Cache"
    case .dismissedPopovers: "Dismissed Popovers"
    case .themeWorkshop: "Theme Workshop"
    case .localDatabase: "Local Database"
    }
  }

  /// Section header the row lives under; page-level items use their category title.
  var section: LocalizedStringResource {
    switch self {
    case .profile: "Profile"
    case .username, .email, .phone, .technicalDetails: "Account"
    case .signOut: "Session"
    case .launchAtLogin: "Startup"
    case .automaticSpellCorrection, .checkSpellingWhileTyping, .shortenSupportedLinks, .sendMessages: "Writing"
    case .syncMessageGestures, .doubleClick, .hold, .swipeToReply, .translationControls,
         .openReplyThreadsInSidePane:
      "Messages"
    case .openChatsCleanup: "Sidebar"
    case .appearance, .theme: "Appearance"
    case .sidebarItemSize, .chatIcon, .sidebarTint: "Sidebar"
    case .messageStyle: "Messages"
    case .preferredSkinTone: "Emoji"
    case .unreadBadgeStyle: "Badges"
    case .compactToolbar: "Toolbar"
    case .centeredChats: "Chat Layout"
    case .fonts, .fontSize: "Typography"
    case .inputDevice, .outputDevice: "Devices"
    case .autoUnmuteOnJoin, .autoMuteWhenAlone: "Grid"
    case .dockBadge: "Dock"
    case .notificationSounds: "Sound"
    case .appearInGlobalSearch: "Discovery"
    case .shareTimeZone: "Time Zone"
    case .autoDownloadMedia, .autoDownloadFiles, .autoDownloadVoiceMessages: "Auto-Download"
    case .connectors: "Connectors"
    case .focusInlineHotkey, .gridMicrophoneHotkey: "Global Hotkeys"
    case .agentSetup: "Agent Setup"
    case .createBot: "Create Bot"
    case .yourBots: "Your Bots"
    case .skilledAgents: "Skilled Agents"
    case .signedInDevices: "Signed-In Devices"
#if SPARKLE
    case .softwareUpdate: "Status"
    case .automaticUpdates, .updateChannel: "Automatic Updates"
#endif
    case .agentActivity, .newThreadAgentPicker, .richContentRenderer, .inlineMathAttachments,
         .richMessageMultiBlockSelection:
      "Agents"
    case .richCopyMarkdownEditing, .selectMultipleMessages, .quickForward: "Messages"
    case .gridTranscription: "Grid"
    case .fileBrowser, .nativeFileDownloads: "Files"
    case .syncEngine, .appPermissions, .connectionSecurity, .macDevtools, .onboarding, .playground: "Tools"
    case .appCache, .mediaCache, .dismissedPopovers: "Recovery"
    case .themeWorkshop: "Appearance"
    case .localDatabase: "Database"
    }
  }

  /// Synonyms people may type that don't appear in the title or section.
  var keywords: [String] {
    switch self {
    case .profile: ["name", "photo", "avatar", "picture", "bio", "memoji"]
    case .username: ["handle", "public name"]
    case .email: ["mail", "address"]
    case .phone: ["number", "mobile"]
    case .technicalDetails: ["account id"]
    case .signOut: ["sign out", "log out", "logout"]
    case .launchAtLogin: ["startup", "open automatically", "boot"]
    case .automaticSpellCorrection: ["autocorrect", "spelling", "typo"]
    case .checkSpellingWhileTyping: ["spellcheck", "underline", "typo"]
    case .shortenSupportedLinks: ["url", "paste", "link titles"]
    case .sendMessages: ["return", "enter", "command", "cmd", "keyboard"]
    case .syncMessageGestures: ["gestures", "devices", "double-click", "hold", "swipe"]
    case .doubleClick: ["gesture", "mouse", "reply", "react"]
    case .hold: ["long press", "gesture"]
    case .swipeToReply: ["gesture", "trackpad", "direction"]
    case .translationControls: ["translate", "language"]
    case .openReplyThreadsInSidePane: ["thread", "replies", "split"]
    case .openChatsCleanup: ["archive", "close", "tabs"]
    case .appearance: ["dark mode", "light mode", "system"]
    case .theme: ["colors", "palette", "accent", "import", "export"]
    case .sidebarItemSize: ["density", "compact", "row height"]
    case .chatIcon: ["symbol", "emoji", "thread icon"]
    case .sidebarTint: ["glass", "translucent", "color"]
    case .messageStyle: ["bubbles", "layout"]
    case .preferredSkinTone: ["emoji"]
    case .unreadBadgeStyle: ["count", "dot", "unread"]
    case .compactToolbar: ["titlebar", "height"]
    case .centeredChats: ["width", "column", "layout", "composer"]
    case .fonts: ["font family", "typeface", "text"]
    case .fontSize: ["font size", "text size", "bigger", "smaller", "zoom"]
    case .inputDevice: ["microphone", "mic"]
    case .outputDevice: ["speaker", "headphones"]
    case .autoUnmuteOnJoin: ["microphone", "call", "room"]
    case .autoMuteWhenAlone: ["microphone", "call", "room"]
    case .dockBadge: ["unread", "count", "icon"]
    case .notificationSounds: ["alert", "mute"]
    case .appearInGlobalSearch: ["username", "find", "discoverable", "visibility"]
    case .shareTimeZone: ["local time", "timezone"]
    case .autoDownloadMedia: ["photos", "images", "videos", "download"]
    case .autoDownloadFiles: ["documents", "attachments", "download"]
    case .autoDownloadVoiceMessages: ["audio", "download"]
    case .connectors: ["integrations", "apps", "linear", "notion", "github"]
    case .focusInlineHotkey: ["shortcut", "keyboard", "global", "activate"]
    case .gridMicrophoneHotkey: ["shortcut", "keyboard", "mute", "unmute", "push to talk"]
    case .agentSetup: ["cli", "codex", "claude", "opencode", "amp", "hermes", "openclaw"]
    case .createBot: ["new bot", "token"]
    case .yourBots: ["manage", "token"]
    case .skilledAgents: ["agents", "mention", "roles"]
    case .signedInDevices: ["sessions", "devices", "revoke", "log out", "security"]
#if SPARKLE
    case .softwareUpdate: ["check for updates", "install", "version"]
    case .automaticUpdates: ["auto update"]
    case .updateChannel: ["beta", "stable", "tip", "nightly"]
#endif
    case .agentActivity: ["working", "spinner", "steps"]
    case .newThreadAgentPicker: ["agent", "thread", "composer"]
    case .richContentRenderer: ["markdown", "agent"]
    case .inlineMathAttachments: ["latex", "formula", "math"]
    case .richMessageMultiBlockSelection: ["select", "copy"]
    case .richCopyMarkdownEditing: ["copy", "paste", "markdown", "formatting"]
    case .selectMultipleMessages: ["select", "forward", "delete"]
    case .quickForward: ["forward"]
    case .gridTranscription: ["transcript", "meeting", "call"]
    case .fileBrowser: ["files window", "browse"]
    case .nativeFileDownloads: ["download", "realtime"]
    case .syncEngine: ["realtime", "sync"]
    case .appPermissions: ["notifications", "microphone", "permissions"]
    case .connectionSecurity: ["protocol", "authentication"]
    case .macDevtools: ["developer tools"]
    case .onboarding: []
    case .playground: ["components", "fixtures"]
    case .appCache: ["clear", "reset", "reload"]
    case .mediaCache: ["clear", "downloads", "storage"]
    case .dismissedPopovers: ["reset", "notices", "tips"]
    case .themeWorkshop: ["colors", "palette"]
    case .localDatabase: ["sqlite", "delete", "reset"]
    }
  }

  /// Rows behind build flags or runtime gates mirror the same condition here.
  var isAvailable: Bool {
    switch self {
    case .newThreadAgentPicker:
      if #available(macOS 26.0, *) {
        return true
      }
      return false
    case .onboarding, .playground, .themeWorkshop, .localDatabase:
#if DEBUG || DEBUG_BUILD
      return true
#else
      return false
#endif
    default:
      return true
    }
  }

  /// Search entries for the visible categories, in sidebar order.
  static func searchEntries(for categories: [SettingsCategory]) -> [SettingsSearchEntry<SettingsSearchItem>] {
    categories.flatMap { category in
      allCases
        .filter { $0.category == category && $0.isAvailable }
        .map { item in
          SettingsSearchEntry(
            id: item,
            title: String(localized: item.title),
            keywords: item.keywords,
            context: [String(localized: item.section), category.title]
          )
        }
    }
  }
}
