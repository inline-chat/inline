import Combine
import Foundation
import SwiftUI

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

  private init() {
    sendsWithCmdEnter = UserDefaults.standard.bool(forKey: "sendsWithCmdEnter")
    automaticSpellCorrection = UserDefaults.standard.object(forKey: "automaticSpellCorrection") as? Bool ?? true
    checkSpellingWhileTyping = UserDefaults.standard.object(forKey: "checkSpellingWhileTyping") as? Bool ?? true
    disableNotificationSound = UserDefaults.standard.bool(forKey: "disableNotificationSound")
    showDockBadgeUnreadDMs = UserDefaults.standard.object(forKey: "showDockBadgeUnreadDMs") as? Bool ?? true
    enableNewMacUI = UserDefaults.standard.bool(forKey: "enableNewMacUI")
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
