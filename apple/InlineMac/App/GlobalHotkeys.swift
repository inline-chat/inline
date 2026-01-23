import AppKit
import InlineKit

/// A lightweight local event monitor that captures global (window-wide) hotkeys
/// and performs predefined actions. Designed to be easily extendable: register
/// additional `Hotkey` items and their corresponding `Action`s as needed.
@MainActor
final class GlobalHotkeys {
  // MARK: Public API

  /// Supported actions that can be triggered by a hotkey.
  enum Action {
    case previousChat
    case nextChat
    case custom(() -> Void) // For future one-off handlers

    fileprivate func perform(using dependencies: AppDependencies) {
      switch self {
        case .previousChat:
          NotificationCenter.default.post(name: .prevChat, object: nil)
        case .nextChat:
          NotificationCenter.default.post(name: .nextChat, object: nil)
        case let .custom(handler):
          handler()
      }
    }
  }

  /// Describes a key-combination and the action it triggers.
  struct Hotkey {
    let key: String // unmodified character (lower-case)
    let modifierFlags: NSEvent.ModifierFlags
    let action: Action
  }

  // MARK: Lifecycle

  private var eventMonitor: Any?
  private var hotkeys: [Hotkey] = []
  private let dependencies: AppDependencies

  init(dependencies: AppDependencies) {
    self.dependencies = dependencies

    // Default Vim-style navigation bindings
    hotkeys.append(Hotkey(key: "k", modifierFlags: [.control], action: .previousChat))
    hotkeys.append(Hotkey(key: "j", modifierFlags: [.control], action: .nextChat))
    hotkeys.append(Hotkey(key: "p", modifierFlags: [.control], action: .previousChat))
    hotkeys.append(Hotkey(key: "n", modifierFlags: [.control], action: .nextChat))

    setupMonitor()
  }

  deinit {
    if let eventMonitor {
      NSEvent.removeMonitor(eventMonitor)
    }
  }

  // Register additional hotkeys at runtime if needed
  func register(key: String, modifiers: NSEvent.ModifierFlags, action: Action) {
    hotkeys.append(Hotkey(key: key.lowercased(), modifierFlags: modifiers, action: action))
  }

  // MARK: Event monitoring

  private func setupMonitor() {
    eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      guard let self else { return event }

      // Match event to a hotkey
      guard let matched = match(event: event) else { return event }

      // Respect text inputs – except when the compose field has focus, where
      // users still expect chat navigation (Ctrl+J/K or Ctrl+N/P) to work.
      if isTextInputFocused && !shouldHandleWhileTyping(matched) {
        return event
      }

      // For navigation keys, ensure we’re in Inbox/Archive; for others it may
      // not matter. Extend this logic per-action as needed.
      switch matched.action {
        case .previousChat, .nextChat:
          guard isChatNavigationRelevant else { return event }
        default:
          break
      }

      matched.action.perform(using: dependencies)
      return nil // swallow the event
    }
  }

  private func match(event: NSEvent) -> Hotkey? {
    guard let char = event.charactersIgnoringModifiers?.lowercased() else { return nil }
    return hotkeys.first(where: { hotkey in
      hotkey.key == char && event.modifierFlags.isSuperset(of: hotkey.modifierFlags)
    })
  }

  /// Allow navigation hotkeys even when the compose text view is the first responder
  /// so users can move between chats without leaving the message field.
  private func shouldHandleWhileTyping(_ hotkey: Hotkey) -> Bool {
    switch hotkey.action {
      case .previousChat, .nextChat:
        break // continue checks below
      default:
        return false
    }

    guard let responder = NSApp.keyWindow?.firstResponder else { return false }

    // Explicitly allow the compose text view (and subclasses) to keep vim navigation active.
    if responder is ComposeNSTextView {
      return true
    }

    // Also allow any NSTextView that uses the compose delegate so future compose variants work.
    if let textView = responder as? NSTextView,
       textView.delegate is ComposeTextViewDelegate {
      return true
    }

    return false
  }

  // MARK: Helper state checks

  private var isChatNavigationRelevant: Bool {
    if dependencies.nav2 != nil {
      return true
    }
    let nav = dependencies.nav
    return nav.selectedTab == .inbox || nav.selectedTab == .archive
  }

  private var isTextInputFocused: Bool {
    guard let responder = NSApp.keyWindow?.firstResponder else { return false }
    return responder is NSTextField ||
      responder is NSTextView ||
      responder is NSSecureTextField ||
      (responder is NSText && (responder as? NSText)?.delegate is NSTextField)
  }
}
