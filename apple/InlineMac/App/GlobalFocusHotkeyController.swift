import AppKit
import Carbon
import InlineMacUI
import Logger

/// Registers Inline's system-global hotkeys through one Carbon event handler.
final class GlobalHotkeyController {
  enum Action: UInt32, Hashable {
    case focusInline = 1
    case gridMicrophone = 2
  }

  private let log = Log.scoped("GlobalHotkeyController")

  private var hotKeyRefs: [Action: EventHotKeyRef] = [:]
  private var handlers: [Action: @MainActor () -> Void] = [:]
  private var eventHandlerRef: EventHandlerRef?
  private var eventHandlerUPP: EventHandlerUPP?

  private let signature: OSType = 0x494E4C4E // 'INLN'

  init() {
    installHandlerIfNeeded()
  }

  deinit {
    // Best-effort cleanup; important to remove the Carbon handler synchronously,
    // otherwise it could fire after deallocation (UAF via `userData`).
    unregisterAll()
    if let eventHandlerRef {
      RemoveEventHandler(eventHandlerRef)
    }
  }

  func applyHotkey(
    action: Action,
    enabled: Bool,
    hotkey: InlineHotkey?,
    onPress: @escaping @MainActor () -> Void
  ) {
    if !Thread.isMainThread {
      log.warning("applyHotkey called off main thread")
    }

    // Always unregister first; makes updates predictable.
    unregister(action)
    handlers[action] = nil

    guard enabled, let hotkey else {
      return
    }

    handlers[action] = onPress
    var hkID = EventHotKeyID(signature: signature, id: action.rawValue)
    var ref: EventHotKeyRef?
    let status = RegisterEventHotKey(
      UInt32(hotkey.keyCode),
      hotkey.carbonModifiers,
      hkID,
      GetApplicationEventTarget(),
      0,
      &ref
    )

    if status != noErr {
      handlers[action] = nil
      log.warning("RegisterEventHotKey failed action=\(action.rawValue): \(status)")
      return
    }

    if let ref {
      hotKeyRefs[action] = ref
    }
    log.trace("Registered global hotkey action=\(action.rawValue): \(hotkey.displayString)")
  }

  private func unregister(_ action: Action) {
    if let hotKeyRef = hotKeyRefs.removeValue(forKey: action) {
      UnregisterEventHotKey(hotKeyRef)
    }
  }

  private func unregisterAll() {
    for action in Array(hotKeyRefs.keys) {
      unregister(action)
    }
    handlers.removeAll()
  }

  private func installHandlerIfNeeded() {
    guard eventHandlerRef == nil else { return }

    var typeSpec = EventTypeSpec(
      eventClass: OSType(kEventClassKeyboard),
      eventKind: UInt32(kEventHotKeyPressed)
    )

    let handler: EventHandlerProcPtr = { _, eventRef, userData in
      guard let eventRef, let userData else { return OSStatus(eventNotHandledErr) }
      let controller = Unmanaged<GlobalHotkeyController>.fromOpaque(userData).takeUnretainedValue()

      var hkID = EventHotKeyID()
      let status = GetEventParameter(
        eventRef,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hkID
      )

      guard status == noErr,
            hkID.signature == controller.signature,
            let action = Action(rawValue: hkID.id),
            let onPress = controller.handlers[action]
      else { return OSStatus(eventNotHandledErr) }

      // Run after the hotkey event returns to avoid re-entrancy issues with AppKit focus changes.
      DispatchQueue.main.async { @MainActor in
        onPress()
      }

      return noErr
    }

    // Keep the UPP alive for the lifetime of this controller.
    // `NewEventHandlerUPP` appears to be missing at link time on newer macOS SDKs.
    // `EventHandlerUPP` is a typealias for the proc pointer on 64-bit, so we can use `handler` directly.
    let upp: EventHandlerUPP = handler
    eventHandlerUPP = upp

    let status = InstallEventHandler(
      GetApplicationEventTarget(),
      upp,
      1,
      &typeSpec,
      UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
      &eventHandlerRef
    )

    if status != noErr {
      log.warning("InstallEventHandler failed: \(status)")
    }
  }
}
