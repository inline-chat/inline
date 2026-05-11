import AppKit
import Foundation
import Logger
import OrderedCollections

/// Add keyboard handling to the application views for global events that could interfere.
/// This should be attached per window.
@MainActor
public class KeyMonitor: Sendable {
  private let ESCAPE_KEY_CODE: UInt16 = 53
  private let V_KEY_CODE: UInt16 = 9
  private static let traceDefaultsKey = "keyMonitorTraceEnabled"
  private let log = Log.scoped(
    "KeyMonitor",
    enableTracing: UserDefaults.standard.bool(forKey: traceDefaultsKey)
  )
  private var escapeHandlers: OrderedDictionary<String, (NSEvent) -> Void> = [:]
  private var textInputCatchAllHandlers: OrderedDictionary<String, (NSEvent) -> Void> = [:]
  private var pasteHandlers: OrderedDictionary<String, (NSEvent) -> Void> = [:]
  private var arrowKeyHandlers: OrderedDictionary<String, (NSEvent) -> Void> = [:]
  private var verticalArrowKeyHandlers: OrderedDictionary<String, (NSEvent) -> Void> = [:]
  private var returnKeyHandlers: OrderedDictionary<String, (NSEvent) -> Void> = [:]
  private var vimNavHandlers: OrderedDictionary<String, (NSEvent) -> Void> = [:]
  // Cmd+1...9: return true only when the handler actually acted.
  private var commandNumberHandlers: OrderedDictionary<String, (NSEvent) -> Bool> = [:]

  private var localEventMonitor: Any?
  private weak var window: NSWindow?

  init() {}

  init(window: NSWindow) {
    attach(window: window)
  }

  // MARK: - Public API

  enum HandlerType {
    case escape
    case textInputCatchAll
    case paste
    case arrowKeys
    case verticalArrowKeys
    case returnKey
    case vimNavigation
  }

  func attach(window: NSWindow?) {
    guard self.window !== window else { return }

    log.trace("Attaching to window \(describe(window)); previous=\(describe(self.window))")
    self.window = window
    if window == nil {
      removeKeyboardMonitoring()
    } else {
      setupKeyboardMonitoringIfNeeded()
    }
  }

  /// Add a handler for a specific event type
  /// It returns a function to call to unsubscribe
  func addHandler(for type: HandlerType, key: String, handler: @escaping (NSEvent) -> Void) -> (() -> Void) {
    log.trace("Adding handler for \(type) with key \(key)")
    switch type {
      case .escape:
        escapeHandlers[key] = handler
        log.trace("Escape handlers after add: \(handlerKeys(escapeHandlers))")
      case .textInputCatchAll:
        textInputCatchAllHandlers[key] = handler
      case .paste:
        pasteHandlers[key] = handler
      case .arrowKeys:
        arrowKeyHandlers[key] = handler
      case .verticalArrowKeys:
        verticalArrowKeyHandlers[key] = handler
      case .returnKey:
        returnKeyHandlers[key] = handler
      case .vimNavigation:
        vimNavHandlers[key] = handler
    }

    return { [weak self] in
      self?.log.trace("Removing handler for \(type) with key \(key)")
      switch type {
        case .escape:
          self?.escapeHandlers.removeValue(forKey: key)
          self?.log.trace("Escape handlers after remove: \(self?.handlerKeys(self?.escapeHandlers ?? [:]) ?? "")")
        case .textInputCatchAll:
          self?.textInputCatchAllHandlers.removeValue(forKey: key)
        case .paste:
          self?.pasteHandlers.removeValue(forKey: key)
        case .arrowKeys:
          self?.arrowKeyHandlers.removeValue(forKey: key)
        case .verticalArrowKeys:
          self?.verticalArrowKeyHandlers.removeValue(forKey: key)
        case .returnKey:
          self?.returnKeyHandlers.removeValue(forKey: key)
        case .vimNavigation:
          self?.vimNavHandlers.removeValue(forKey: key)
      }
    }
  }

  func removeHandler(for type: HandlerType, key: String) {
    log.trace("Removing handler for \(type) with key \(key)")
    switch type {
      case .escape:
        escapeHandlers.removeValue(forKey: key)
        log.trace("Escape handlers after explicit remove: \(handlerKeys(escapeHandlers))")
      case .textInputCatchAll:
        textInputCatchAllHandlers.removeValue(forKey: key)
      case .paste:
        pasteHandlers.removeValue(forKey: key)
      case .arrowKeys:
        arrowKeyHandlers.removeValue(forKey: key)
      case .verticalArrowKeys:
        verticalArrowKeyHandlers.removeValue(forKey: key)
      case .returnKey:
        returnKeyHandlers.removeValue(forKey: key)
      case .vimNavigation:
        vimNavHandlers.removeValue(forKey: key)
    }
  }

  // MARK: - Cmd+1...9

  /// Add a Cmd+1...9 handler. Return true only if the handler consumed the shortcut.
  func addCommandNumberHandler(
    key: String,
    handler: @escaping (NSEvent) -> Bool
  ) -> (() -> Void) {
    log.trace("Adding command number handler with key \(key)")
    commandNumberHandlers[key] = handler
    return { [weak self] in
      self?.log.trace("Removing command number handler with key \(key)")
      self?.commandNumberHandlers.removeValue(forKey: key)
    }
  }

  // MARK: - Monitor

  private func setupKeyboardMonitoringIfNeeded() {
    guard localEventMonitor == nil else {
      log.trace("Keyboard monitoring already installed for window \(describe(window))")
      return
    }

    log.trace("Installing local key monitor for window \(describe(window))")
    localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      guard let self else {
        return event
      }
      guard let window, event.window == window else {
        log.trace(
          "Ignoring key event for different window; keyCode=\(event.keyCode) eventWindow=\(describe(event.window)) monitorWindow=\(describe(window))"
        )
        return event
      }

      // Cmd+1...9 (space/tab switching).
      let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
      if modifiers == [.command],
         let char = event.charactersIgnoringModifiers?.first,
         "123456789".contains(char)
      {
        let handled = callCommandNumberHandler(event: event)
        if handled { return nil }
      }

      if event.keyCode == ESCAPE_KEY_CODE {
        log.trace("Escape keydown; handlers=\(handlerKeys(escapeHandlers))")
        let handled = callHandler(for: .escape, event: event)
        log.trace("Escape keydown handled=\(handled)")
        if handled { return nil }
      }

      // Check for vertical arrow keys used for list navigation (up/down).
      if event.keyCode == 125 || event.keyCode == 126 {
        let handledVertical = callHandler(for: .verticalArrowKeys, event: event)
        if handledVertical { return nil }
      }

      // Check for all arrow keys.
      if event.keyCode == 125 || event.keyCode == 126 || event.keyCode == 123 || event.keyCode == 124 {
        let handled = callHandler(for: .arrowKeys, event: event)
        if handled { return nil }
      }

      // Check for return key
      if event.keyCode == 36 {
        let handled = callHandler(for: .returnKey, event: event)
        if handled { return nil }
      }

      // Check for Vim-style navigation (ctrl+j/k/n/p)
      if event.modifierFlags.contains(.control),
         let char = event.charactersIgnoringModifiers?.lowercased(),
         ["j", "k", "n", "p"].contains(char)
      {
        let handled = callHandler(for: .vimNavigation, event: event)
        if handled { return nil }
      }

      // Check for Cmd+V (paste) when no text input is focused
      if event.keyCode == V_KEY_CODE,
         event.modifierFlags.contains(.command),
         !isTextInputCurrentlyFocused()
      {
        let handled = callPasteHandler(event: event)
        if handled { return nil }
      }

      log.trace("event: \(event)")

      // Only handle the event if we should intercept it
      if shouldInterceptKeyEvent(event) == true {
        let handled = callHandler(for: .textInputCatchAll, event: event)
        if handled { return nil } // Prevent further processing
      }

      // Otherwise, pass the event along
      return event
    }
  }

  private func removeKeyboardMonitoring() {
    guard let monitor = localEventMonitor else { return }
    log.trace("Removing local key monitor for window \(describe(window))")
    NSEvent.removeMonitor(monitor)
    localEventMonitor = nil
  }

  private func shouldInterceptKeyEvent(_ event: NSEvent) -> Bool {
    // First, check if the current first responder is a text input control
    if isTextInputCurrentlyFocused() {
      log.trace("Ignoring event as text input is focused")
      return false
    }

    // Then check if it's a character key (not a modifier or special key)
    if let characters = event.characters, !characters.isEmpty {
      // Ignore if event has command, control, or option modifiers
      if event.modifierFlags.contains(.command) ||
        event.modifierFlags.contains(.control) ||
        event.modifierFlags.contains(.option)
      {
        log.trace("Ignoring event as it has modifier flags")
        return false
      }

      return true
    }

    return false
  }

  private func isTextInputCurrentlyFocused() -> Bool {
    guard let firstResponder = window?.firstResponder
    else {
      return false
    }

    // Check if the first responder is a text input control
    return firstResponder is NSTextField ||
      firstResponder is NSTextView ||
      firstResponder is NSSecureTextField ||
      // Check if it's a field editor for a text field
      (firstResponder is NSText && (firstResponder as? NSText)?.delegate is NSTextField)
  }

  // Returns if it could find a handler for it
  private func callHandler(for type: HandlerType, event: NSEvent) -> Bool {
    switch type {
      case .escape:
        // Last one is most specific.
        if let key = escapeHandlers.keys.last, let last = escapeHandlers[key] {
          log.trace("Calling escape handler key=\(key)")
          last(event)
          return true
        } else {
          log.trace("No escape handler registered")
          return false
        }
      case .textInputCatchAll:
        // only call the last one as otherwise multiple text inputs will fight
        if let last = textInputCatchAllHandlers.values.last {
          last(event)
          return true
        } else {
          return false
        }
      case .paste:
        return callPasteHandler(event: event)
      case .arrowKeys:
        // only call the last one as otherwise multiple handlers will fight
        if let last = arrowKeyHandlers.values.last {
          last(event)
          return true
        } else {
          return false
        }
      case .verticalArrowKeys:
        // only call the last one as otherwise multiple handlers will fight
        if let last = verticalArrowKeyHandlers.values.last {
          last(event)
          return true
        } else {
          return false
        }
      case .returnKey:
        // only call the last one as otherwise multiple handlers will fight
        if let last = returnKeyHandlers.values.last {
          last(event)
          return true
        } else {
          return false
        }
      case .vimNavigation:
        if let last = vimNavHandlers.values.last {
          last(event)
          return true
        } else {
          return false
        }
    }
  }

  private func callCommandNumberHandler(event: NSEvent) -> Bool {
    guard let last = commandNumberHandlers.values.last else { return false }
    return last(event)
  }

  private func callPasteHandler(event: NSEvent) -> Bool {
    // only call the last one as otherwise multiple handlers will fight
    if let last = pasteHandlers.values.last {
      last(event)
      return true
    } else {
      return false
    }
  }

  deinit {
    if let monitor = localEventMonitor {
      NSEvent.removeMonitor(monitor)
    }
  }

  private func handlerKeys<Value>(_ handlers: OrderedDictionary<String, Value>) -> String {
    let keys = handlers.keys.joined(separator: ",")
    return keys.isEmpty ? "<none>" : keys
  }

  private func describe(_ window: NSWindow?) -> String {
    guard let window else { return "nil" }
    return "\(window.windowNumber):\(window.title)"
  }
}
