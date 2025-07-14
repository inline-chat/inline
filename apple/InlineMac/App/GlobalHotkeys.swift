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
        case .custom(let handler):
          handler()
      }
    }
  }

  /// Describes a key-combination and the action it triggers.
  struct Hotkey {
    let key: String                      // unmodified character (lower-case)
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

      // Respect text inputs – don’t interfere while typing.
      // if self.isTextInputFocused { return event }

      // Match event to a hotkey
      guard let matched = self.match(event: event) else { return event }

      // For navigation keys, ensure we’re in Inbox/Archive; for others it may
      // not matter. Extend this logic per-action as needed.
      switch matched.action {
        case .previousChat, .nextChat:
          guard self.isChatNavigationRelevant else { return event }
        default:
          break
      }

      matched.action.perform(using: self.dependencies)
      return nil // swallow the event
    }
  }

  private func match(event: NSEvent) -> Hotkey? {
    guard let char = event.charactersIgnoringModifiers?.lowercased() else { return nil }
    return hotkeys.first(where: { hotkey in
      hotkey.key == char && event.modifierFlags.isSuperset(of: hotkey.modifierFlags)
    })
  }

  // MARK: Helper state checks
  private var isChatNavigationRelevant: Bool {
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