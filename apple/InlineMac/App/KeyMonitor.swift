import AppKit
import Foundation
import Logger
import OrderedCollections

/// Add keyboard handling to the application views for global events that could interfere
/// This should be initialized per window
@MainActor
class KeyMonitor: Sendable {
  private let ESCAPE_KEY_CODE: UInt16 = 53
  private let log = Log.scoped("KeyMonitor", enableTracing: false)
  private var escapeHandlers: OrderedDictionary<String, (NSEvent) -> Void> = [:]
  private var textInputCatchAllHandlers: OrderedDictionary<String, (NSEvent) -> Void> = [:]

  private var localEventMonitor: Any?
  private var window: NSWindow

  init(window: NSWindow) {
    self.window = window
    setupKeyboardMonitoring()
  }

  // MARK: - Public API

  enum HandlerType {
    case escape
    case textInputCatchAll
  }

  /// Add a handler for a specific event type
  /// It returns a function to call to unsubscribe
  func addHandler(for type: HandlerType, key: String, handler: @escaping (NSEvent) -> Void) -> (() -> Void) {
    log.trace("Adding handler for \(type) with key \(key)")
    switch type {
      case .escape:
        escapeHandlers[key] = handler
      case .textInputCatchAll:
        textInputCatchAllHandlers[key] = handler
    }

    return { [weak self] in
      self?.log.trace("Removing handler for \(type) with key \(key)")
      switch type {
        case .escape:
          self?.escapeHandlers.removeValue(forKey: key)
        case .textInputCatchAll:
          self?.textInputCatchAllHandlers.removeValue(forKey: key)
      }
    }
  }

  // MARK: - Monitor

  private func setupKeyboardMonitoring() {
    localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      guard let self else {
        return event
      }
      // Is this really needed?
      guard event.window == window else {
        return event
      }

      if event.keyCode == ESCAPE_KEY_CODE {
        let handled = callHandler(for: .escape, event: event)
        if handled { return nil }
      }
      
      
      self.log.trace("event: \(event)")

      // Only handle the event if we should intercept it
      if shouldInterceptKeyEvent(event) == true {
        let handled = callHandler(for: .textInputCatchAll, event: event)
        if handled { return nil } // Prevent further processing
      }

      // Otherwise, pass the event along
      return event
    }
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
    guard let firstResponder = window.firstResponder
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
        // last one is most specific, but we'll have to remove it somehow
      if let last = escapeHandlers.values.last {
          last(event)
          return true
        } else {
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
    }
  }

  deinit {
    if let monitor = localEventMonitor {
      NSEvent.removeMonitor(monitor)
    }
  }
}
