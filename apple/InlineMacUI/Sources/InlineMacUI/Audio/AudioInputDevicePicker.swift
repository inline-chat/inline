import AppKit
import InlineRTC
import SwiftUI

/// A reusable native microphone menu.
///
/// The picker owns presentation of automatic routing, explicit preferences,
/// unavailable preferred devices, SF Symbols, and native checked state. It has
/// no dependency on Grid, rooms, or RTC state.
public struct AudioInputDevicePicker: NSViewRepresentable {
  @Binding private var selection: AudioInputSelection
  private let automaticDeviceName: String
  private let devices: [AudioInputDeviceDescriptor]
  private let refresh: () -> Void

  public init(
    selection: Binding<AudioInputSelection>,
    automaticDeviceName: String,
    devices: [AudioInputDeviceDescriptor],
    refresh: @escaping () -> Void
  ) {
    _selection = selection
    self.automaticDeviceName = automaticDeviceName
    self.devices = devices
    self.refresh = refresh
  }

  public func makeCoordinator() -> Coordinator {
    Coordinator(self)
  }

  public func makeNSView(context: Context) -> NSButton {
    let button = NSButton(
      image: NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil) ?? NSImage(),
      target: context.coordinator,
      action: #selector(Coordinator.showMenu(_:))
    )
    button.isBordered = false
    button.imagePosition = .imageOnly
    button.imageScaling = .scaleProportionallyDown
    button.toolTip = "Choose microphone"
    button.setAccessibilityLabel("Choose microphone")
    update(button, coordinator: context.coordinator)
    context.coordinator.perform(#selector(Coordinator.refreshDevices), with: nil, afterDelay: 0)
    return button
  }

  public func updateNSView(_ button: NSButton, context: Context) {
    context.coordinator.parent = self
    update(button, coordinator: context.coordinator)
  }

  private func update(_ button: NSButton, coordinator: Coordinator) {
    let menu = NSMenu()
    menu.autoenablesItems = false
    menu.showsStateColumn = true
    menu.delegate = coordinator

    var choices: [AudioInputSelection] = []
    addChoice(
      .automatic,
      title: "Auto (\(automaticDeviceName))",
      symbol: "gearshape.2",
      to: menu,
      choices: &choices,
      coordinator: coordinator
    )
    menu.addItem(.separator())

    for device in devices {
      addChoice(
        .device(id: device.id, rememberedName: device.name),
        title: device.name,
        symbol: device.systemImage,
        to: menu,
        choices: &choices,
        coordinator: coordinator
      )
    }

    if case let .device(_, rememberedName) = selection,
       resolvedSelectedDeviceID == nil {
      if !devices.isEmpty {
        menu.addItem(.separator())
      }
      addChoice(
        selection,
        title: "\(rememberedName) (Unavailable)",
        symbol: "mic.slash",
        to: menu,
        choices: &choices,
        coordinator: coordinator
      )
    }

    coordinator.choices = choices
    button.menu = menu
  }

  private func addChoice(
    _ choice: AudioInputSelection,
    title: String,
    symbol: String,
    to menu: NSMenu,
    choices: inout [AudioInputSelection],
    coordinator: Coordinator
  ) {
    let item = NSMenuItem(title: title, action: #selector(Coordinator.selectChoice(_:)), keyEquivalent: "")
    item.target = coordinator
    item.tag = choices.count
    item.state = isSelected(choice) ? .on : .off
    item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
    item.isEnabled = true
    choices.append(choice)
    menu.addItem(item)
  }

  private func isSelected(_ choice: AudioInputSelection) -> Bool {
    switch (selection, choice) {
    case (.automatic, .automatic):
      return true
    case let (.device(selectedID, selectedName), .device(choiceID, choiceName)):
      if let resolvedSelectedDeviceID { return resolvedSelectedDeviceID == choiceID }
      // Keep the remembered unavailable choice visibly checked.
      return selectedID == choiceID && selectedName == choiceName
    default:
      return false
    }
  }

  /// Device IDs are authoritative. Name matching repairs a reconnected device
  /// only when the result is unambiguous; duplicate AirPods/headset names must
  /// fall back rather than silently check and route to the wrong microphone.
  private var resolvedSelectedDeviceID: String? {
    selection.resolvedDeviceID(in: devices)
  }

  @MainActor
  public final class Coordinator: NSObject, NSMenuDelegate {
    fileprivate var parent: AudioInputDevicePicker
    fileprivate var choices: [AudioInputSelection] = []

    fileprivate init(_ parent: AudioInputDevicePicker) {
      self.parent = parent
    }

    @objc fileprivate func selectChoice(_ item: NSMenuItem) {
      guard choices.indices.contains(item.tag) else { return }
      parent.selection = choices[item.tag]
    }

    @objc fileprivate func showMenu(_ sender: NSButton) {
      parent.refresh()
      sender.menu?.popUp(
        positioning: nil,
        at: NSPoint(x: 0, y: sender.bounds.maxY + 4),
        in: sender
      )
    }

    public func menuWillOpen(_: NSMenu) {
      parent.refresh()
    }

    @objc fileprivate func refreshDevices() {
      parent.refresh()
    }
  }
}
