import AppKit
import Combine
import Foundation
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

final class AppSettings: ObservableObject {
  static let shared = AppSettings()

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

  // MARK: - Appearance

  @Published var appearance: AppAppearance {
    didSet {
      UserDefaults.standard.set(appearance.rawValue, forKey: "appAppearance")
    }
  }

  // MARK: - Sidebar

  @Published var showSidebarMessagePreview: Bool {
    didSet {
      UserDefaults.standard.set(showSidebarMessagePreview, forKey: "showSidebarMessagePreview")
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

  // MARK: - Experimental Settings

  @Published var enableNewMacUI: Bool {
    didSet {
      UserDefaults.standard.set(enableNewMacUI, forKey: "enableNewMacUI")
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
    if let storedAppearance = UserDefaults.standard.string(forKey: "appAppearance"),
       let appearanceValue = AppAppearance(rawValue: storedAppearance) {
      appearance = appearanceValue
    } else {
      appearance = .system
    }
    if let storedShowPreview = UserDefaults.standard.object(forKey: "showSidebarMessagePreview") as? Bool {
      showSidebarMessagePreview = storedShowPreview
    } else {
      showSidebarMessagePreview = true
    }
    disableNotificationSound = UserDefaults.standard.bool(forKey: "disableNotificationSound")
    showDockBadgeUnreadDMs = UserDefaults.standard.object(forKey: "showDockBadgeUnreadDMs") as? Bool ?? true
    enableNewMacUI = UserDefaults.standard.bool(forKey: "enableNewMacUI")
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
