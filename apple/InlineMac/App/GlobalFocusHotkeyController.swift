import AppKit
import Carbon
import InlineMacUI
import Logger

/// Registers a system-global hotkey (works even when Inline isn't focused) and triggers a handler.
final class GlobalFocusHotkeyController {
  private let log = Log.scoped("GlobalFocusHotkeyController")

  private var hotKeyRef: EventHotKeyRef?
  private var eventHandlerRef: EventHandlerRef?
  private var eventHandlerUPP: EventHandlerUPP?

  private let signature: OSType = 0x494E4C4E // 'INLN'
  private let hotKeyID: UInt32 = 1

  private let onPress: () -> Void

  init(onPress: @escaping () -> Void) {
    self.onPress = onPress
    installHandlerIfNeeded()
  }

  deinit {
    // Best-effort cleanup; important to remove the Carbon handler synchronously,
    // otherwise it could fire after deallocation (UAF via `userData`).
    unregister()
    if let eventHandlerRef {
      RemoveEventHandler(eventHandlerRef)
    }
  }

  func applyHotkey(enabled: Bool, hotkey: InlineHotkey?) {
    if !Thread.isMainThread {
      log.warning("applyHotkey called off main thread")
    }

    // Always unregister first; makes updates predictable.
    unregister()

    guard enabled, let hotkey else {
      return
    }

    var hkID = EventHotKeyID(signature: signature, id: hotKeyID)
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
      log.warning("RegisterEventHotKey failed: \(status)")
      return
    }

    hotKeyRef = ref
    log.debug("Registered global hotkey: \(hotkey.displayString)")
  }

  private func unregister() {
    if let hotKeyRef {
      UnregisterEventHotKey(hotKeyRef)
      self.hotKeyRef = nil
    }
  }

  private func installHandlerIfNeeded() {
    guard eventHandlerRef == nil else { return }

    var typeSpec = EventTypeSpec(
      eventClass: OSType(kEventClassKeyboard),
      eventKind: UInt32(kEventHotKeyPressed)
    )

    let handler: EventHandlerProcPtr = { _, eventRef, userData in
      guard let eventRef, let userData else { return noErr }
      let controller = Unmanaged<GlobalFocusHotkeyController>.fromOpaque(userData).takeUnretainedValue()

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

      guard status == noErr else { return noErr }
      guard hkID.signature == controller.signature, hkID.id == controller.hotKeyID else { return noErr }

      DispatchQueue.main.async {
        controller.onPress()
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
