import AVFoundation
import Combine
import Logger
import SwiftUI

struct VoiceInputDevice: Equatable, Identifiable, Sendable {
  let id: String
  let name: String
  let systemImage: String
}

struct VoiceInputState: Equatable, Sendable {
  let devices: [VoiceInputDevice]
  let selectedDeviceId: VoiceInputDevice.ID?
  let preferredDeviceId: VoiceInputDevice.ID?
  let pendingDeviceId: VoiceInputDevice.ID?

  static let empty = VoiceInputState(
    devices: [],
    selectedDeviceId: nil,
    preferredDeviceId: nil,
    pendingDeviceId: nil
  )

  var selectedDevice: VoiceInputDevice? {
    guard let selectedDeviceId else { return nil }
    return devices.first { $0.id == selectedDeviceId }
  }

  var preferredDevice: VoiceInputDevice? {
    guard let preferredDeviceId else { return nil }
    return devices.first { $0.id == preferredDeviceId }
  }

  var visibleDevice: VoiceInputDevice? {
    guard let visibleSelectionId else { return nil }
    return devices.first { $0.id == visibleSelectionId }
  }

  var visibleSelectionId: VoiceInputDevice.ID? {
    if let pendingDeviceId, devices.contains(where: { $0.id == pendingDeviceId }) {
      return pendingDeviceId
    }

    if let preferredDeviceId, devices.contains(where: { $0.id == preferredDeviceId }) {
      return preferredDeviceId
    }

    if let selectedDeviceId, devices.contains(where: { $0.id == selectedDeviceId }) {
      return selectedDeviceId
    }

    return nil
  }

  var checkedDeviceId: VoiceInputDevice.ID? {
    availablePreferredDeviceId
  }

  var isAutoSelected: Bool {
    availablePreferredDeviceId == nil && pendingDeviceId == nil
  }

  var currentDefaultDeviceName: String? {
    guard isAutoSelected else { return nil }
    return selectedDevice?.name
  }

  var isSwitchingInput: Bool {
    guard let pendingDeviceId else { return false }
    return pendingDeviceId != selectedDeviceId
  }

  var buttonSystemImage: String {
    visibleDevice?.systemImage ?? selectedDevice?.systemImage ?? preferredDevice?.systemImage ?? "ellipsis"
  }

  private var availablePreferredDeviceId: VoiceInputDevice.ID? {
    guard let preferredDeviceId, devices.contains(where: { $0.id == preferredDeviceId }) else {
      return nil
    }

    return preferredDeviceId
  }
}

enum VoiceInputPreferencePersistence: Sendable {
  case persistent
  case runtimeOnly
}

@MainActor
final class VoiceInputController: ObservableObject {
  static let shared = VoiceInputController()

  @Published private(set) var state = VoiceInputState.empty

  private let log = Log.scoped("VoiceInputController")
  private let defaults: UserDefaults
  private var runtimePreference: RuntimePreference = .persisted
  private var pendingDeviceId: VoiceInputDevice.ID?
  private var settleTask: Task<Void, Never>?

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  var preferredDeviceId: VoiceInputDevice.ID? {
    activePreferredDeviceId
  }

  private var storedPreferredDeviceId: VoiceInputDevice.ID? {
    get {
      defaults.string(forKey: Self.preferredDeviceKey)
    }
    set {
      if let newValue, !newValue.isEmpty {
        defaults.set(newValue, forKey: Self.preferredDeviceKey)
      } else {
        defaults.removeObject(forKey: Self.preferredDeviceKey)
      }
    }
  }

  @discardableResult
  func refresh(in session: AVAudioSession = .sharedInstance()) -> VoiceInputState {
    updateState(in: session, context: "refresh")
    return state
  }

  @discardableResult
  func applyPreferredInput(to session: AVAudioSession = .sharedInstance()) throws -> VoiceInputState {
    guard let preferredDeviceId = activePreferredDeviceId else {
      log.debug("apply preferred=nil before \(routeSnapshot(for: session))")
      try session.setPreferredInput(nil)
      updateState(in: session, context: "apply preferred=nil")
      return state
    }

    guard let input = input(matching: preferredDeviceId, in: session) else {
      log.debug("apply preferred unavailable id=\(preferredDeviceId) before \(routeSnapshot(for: session))")
      try session.setPreferredInput(nil)
      updateState(in: session, context: "apply preferred unavailable fallback auto")
      return state
    }

    log.debug("apply preferred id=\(preferredDeviceId) input=\(Self.portSummary(input)) before \(routeSnapshot(for: session))")
    try session.setPreferredInput(input)
    updateState(in: session, context: "apply preferred")
    return state
  }

  @discardableResult
  func selectAutomaticInput(
    persistence: VoiceInputPreferencePersistence = .persistent,
    in session: AVAudioSession = .sharedInstance()
  ) throws -> VoiceInputState {
    let unchanged: Bool
    switch persistence {
    case .persistent:
      unchanged = storedPreferredDeviceId == nil && runtimePreference == .persisted
    case .runtimeOnly:
      unchanged = runtimePreference == .automatic
    }

    guard !(unchanged && session.preferredInput == nil && pendingDeviceId == nil) else {
      log.debug("select auto unchanged \(routeSnapshot(for: session))")
      updateState(in: session, context: "select auto unchanged")
      return state
    }

    let previousStoredDeviceId = storedPreferredDeviceId
    let previousRuntimePreference = runtimePreference
    pendingDeviceId = nil
    settleTask?.cancel()

    switch persistence {
    case .persistent:
      runtimePreference = .persisted
      storedPreferredDeviceId = nil
    case .runtimeOnly:
      runtimePreference = .automatic
    }

    updateState(in: session, context: "select auto intent")

    do {
      log.debug("select auto setPreferredInput nil before \(routeSnapshot(for: session))")
      try session.setPreferredInput(nil)
    } catch {
      storedPreferredDeviceId = previousStoredDeviceId
      runtimePreference = previousRuntimePreference
      updateState(in: session, context: "select auto failed")
      log.error("select auto failed \(routeSnapshot(for: session))", error: error)
      throw error
    }

    updateState(in: session, context: "select auto applied")
    return state
  }

  @discardableResult
  func selectPreferredInput(
    deviceId: VoiceInputDevice.ID,
    persistence: VoiceInputPreferencePersistence = .persistent,
    in session: AVAudioSession = .sharedInstance()
  ) throws -> VoiceInputState {
    let currentState = inputState(for: session)

    if deviceId == pendingDeviceId, currentState.selectedDeviceId != deviceId {
      log.debug("select already pending id=\(deviceId) \(routeSnapshot(for: session))")
      updateState(in: session, context: "select already pending")
      return state
    }

    if deviceId == activePreferredDeviceId, currentState.selectedDeviceId == deviceId {
      log.debug("select unchanged id=\(deviceId) \(routeSnapshot(for: session))")
      updateState(in: session, context: "select unchanged")
      return state
    }

    guard let input = input(matching: deviceId, in: session) else {
      log.debug("select unavailable id=\(deviceId) \(routeSnapshot(for: session))")
      throw VoiceInputError.inputUnavailable
    }

    let previousStoredDeviceId = storedPreferredDeviceId
    let previousRuntimePreference = runtimePreference
    pendingDeviceId = deviceId

    switch persistence {
    case .persistent:
      runtimePreference = .persisted
      storedPreferredDeviceId = deviceId
    case .runtimeOnly:
      runtimePreference = .device(deviceId)
    }

    updateState(in: session, context: "select intent")

    do {
      log.debug("select setPreferredInput id=\(deviceId) input=\(Self.portSummary(input)) before \(routeSnapshot(for: session))")
      try session.setPreferredInput(input)
    } catch {
      storedPreferredDeviceId = previousStoredDeviceId
      runtimePreference = previousRuntimePreference
      pendingDeviceId = nil
      updateState(in: session, context: "select failed")
      log.error("select failed id=\(deviceId) \(routeSnapshot(for: session))", error: error)
      throw error
    }

    updateState(in: session, context: "select applied")
    scheduleSettleLog()
    return state
  }

  func logRouteChange(reason: AVAudioSession.RouteChangeReason?, in session: AVAudioSession = .sharedInstance()) {
    updateState(in: session, context: "route change \(Self.routeReasonName(reason))")
  }

  private func updateState(in session: AVAudioSession, context: String) {
    let next = inputState(for: session)

    if let pendingDeviceId {
      let hasPendingDevice = next.devices.contains { $0.id == pendingDeviceId }
      if !hasPendingDevice || next.selectedDeviceId == pendingDeviceId {
        self.pendingDeviceId = nil
        settleTask?.cancel()
      }
    }

    state = inputState(for: session)
    log.debug("\(context) \(routeSnapshot(for: session)) state=\(stateSummary(state))")
  }

  private func inputState(for session: AVAudioSession) -> VoiceInputState {
    let inputs = session.availableInputs ?? []
    let devices = inputs.map { input in
      VoiceInputDevice(
        id: Self.inputId(for: input),
        name: Self.displayName(for: input),
        systemImage: Self.systemImage(for: input)
      )
    }

    return VoiceInputState(
      devices: devices,
      selectedDeviceId: Self.selectedInputId(for: session, inputs: inputs),
      preferredDeviceId: activePreferredDeviceId,
      pendingDeviceId: pendingDeviceId
    )
  }

  private var activePreferredDeviceId: VoiceInputDevice.ID? {
    switch runtimePreference {
    case .persisted:
      return storedPreferredDeviceId
    case .automatic:
      return nil
    case let .device(deviceId):
      return deviceId
    }
  }

  private func input(
    matching deviceId: VoiceInputDevice.ID,
    in session: AVAudioSession
  ) -> AVAudioSessionPortDescription? {
    session.availableInputs?.first { Self.inputId(for: $0) == deviceId }
  }

  private static func selectedInputId(
    for session: AVAudioSession,
    inputs: [AVAudioSessionPortDescription]
  ) -> String? {
    let ids = Set(inputs.map { inputId(for: $0) })
    let currentId = session.currentRoute.inputs.first.map { inputId(for: $0) }
    if let currentId, ids.contains(currentId) {
      return currentId
    }

    return nil
  }

  private func scheduleSettleLog() {
    settleTask?.cancel()
    settleTask = Task { @MainActor [weak self] in
      try? await Task.sleep(nanoseconds: 1_200_000_000)
      guard let self, !Task.isCancelled else { return }
      self.settlePendingSelection(in: .sharedInstance())
    }
  }

  private func settlePendingSelection(in session: AVAudioSession) {
    updateState(in: session, context: "select settle")

    guard let pendingDeviceId else { return }
    log.warning("select unresolved id=\(pendingDeviceId) \(routeSnapshot(for: session)) state=\(stateSummary(state))")
    self.pendingDeviceId = nil
    updateState(in: session, context: "select unresolved")
  }

  private static func inputId(for input: AVAudioSessionPortDescription) -> String {
    guard !input.uid.isEmpty else {
      return "\(input.portType.rawValue):\(input.portName)"
    }

    return input.uid
  }

  private static func displayName(for input: AVAudioSessionPortDescription) -> String {
    guard !input.portName.isEmpty else {
      return "Built-in Microphone"
    }

    return input.portName
  }

  private func routeSnapshot(for session: AVAudioSession) -> String {
    let available = (session.availableInputs ?? [])
      .map(Self.portSummary)
      .joined(separator: ";")
    let currentInputs = session.currentRoute.inputs
      .map(Self.portSummary)
      .joined(separator: ";")
    let currentOutputs = session.currentRoute.outputs
      .map(Self.portSummary)
      .joined(separator: ";")
    let preferredInput = session.preferredInput.map(Self.portSummary) ?? "nil"

    return "category=\(session.category.rawValue) mode=\(session.mode.rawValue) storedPreferred=\(storedPreferredDeviceId ?? "nil") runtimePreference=\(runtimePreference.summary) activePreferred=\(activePreferredDeviceId ?? "nil") pending=\(pendingDeviceId ?? "nil") sessionPreferred=\(preferredInput) currentInputs=[\(currentInputs)] currentOutputs=[\(currentOutputs)] available=[\(available)]"
  }

  private func stateSummary(_ state: VoiceInputState) -> String {
    "selected=\(state.selectedDeviceId ?? "nil") preferred=\(state.preferredDeviceId ?? "nil") pending=\(state.pendingDeviceId ?? "nil") visible=\(state.visibleSelectionId ?? "nil") devices=\(state.devices.count)"
  }

  private static func portSummary(_ port: AVAudioSessionPortDescription) -> String {
    let id = inputId(for: port)
    return "\(port.portType.rawValue):\(port.portName):\(id)"
  }

  private static func routeReasonName(_ reason: AVAudioSession.RouteChangeReason?) -> String {
    guard let reason else { return "nil" }

    switch reason {
    case .unknown:
      return "unknown"
    case .newDeviceAvailable:
      return "newDeviceAvailable"
    case .oldDeviceUnavailable:
      return "oldDeviceUnavailable"
    case .categoryChange:
      return "categoryChange"
    case .override:
      return "override"
    case .wakeFromSleep:
      return "wakeFromSleep"
    case .noSuitableRouteForCategory:
      return "noSuitableRouteForCategory"
    case .routeConfigurationChange:
      return "routeConfigurationChange"
    @unknown default:
      return "unknown(\(reason.rawValue))"
    }
  }

  private static func systemImage(for input: AVAudioSessionPortDescription) -> String {
    let name = input.portName.localizedLowercase

    switch input.portType {
    case .builtInMic:
      return "iphone"
    case .bluetoothA2DP, .bluetoothHFP, .bluetoothLE:
      return name.contains("airpods") ? "airpods" : "headphones"
    case .headsetMic:
      return name.contains("airpods") ? "airpods" : "headphones"
    case .carAudio:
      return "car.fill"
    case .lineIn:
      return "waveform"
    case .usbAudio:
      return "cable.connector"
    default:
      return "mic.fill"
    }
  }

  private static let preferredDeviceKey = "chat.inline.voiceInput.preferredDeviceId"

  private enum RuntimePreference: Equatable {
    case persisted
    case automatic
    case device(VoiceInputDevice.ID)

    var summary: String {
      switch self {
      case .persisted:
        return "persisted"
      case .automatic:
        return "automatic"
      case let .device(deviceId):
        return "device(\(deviceId))"
      }
    }
  }
}

enum VoiceInputError: LocalizedError {
  case inputUnavailable

  var errorDescription: String? {
    switch self {
    case .inputUnavailable:
      "Microphone input is unavailable."
    }
  }
}

@MainActor
struct VoiceInputPickerButton: View {
  @ObservedObject var controller: VoiceInputController
  let isEnabled: Bool
  let onSelectAuto: @MainActor () -> Void
  let onSelect: @MainActor (VoiceInputDevice.ID) -> Void

  var body: some View {
    Menu {
      Button(action: onSelectAuto) {
        Label {
          VStack(alignment: .leading, spacing: 1) {
            Text("Auto")
            autoSubtitle
          }
        } icon: {
          Image(systemName: autoIconSystemImage)
        }
      }

      Section("Pick a preferred device") {
        ForEach(state.devices) { device in
          Button {
            onSelect(device.id)
          } label: {
            Label {
              Text(device.name)
            } icon: {
              if device.id == state.pendingDeviceId {
                ProgressView()
                  .controlSize(.small)
              } else {
                Image(systemName: device.id == state.checkedDeviceId ? "checkmark" : device.systemImage)
              }
            }
          }
        }
      }
    } label: {
      ZStack {
        Image(systemName: state.buttonSystemImage)
          .opacity(state.isSwitchingInput ? 0.2 : 1)

        if state.isSwitchingInput {
          ProgressView()
            .controlSize(.small)
        }
      }
    }
    .disabled(!isEnabled)
    .accessibilityLabel("Microphone")
    .accessibilityValue(accessibilityValue)
  }

  private var state: VoiceInputState {
    controller.state
  }

  @ViewBuilder
  private var autoSubtitle: some View {
    if let deviceName = state.currentDefaultDeviceName {
      Text("Current: \(deviceName)")
        .font(.caption)
        .foregroundStyle(.secondary)
    } else {
      Text("System default")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  private var autoIconSystemImage: String {
    state.isAutoSelected ? "checkmark" : "mic.fill"
  }

  private var accessibilityValue: String {
    let deviceName = state.visibleDevice?.name ?? state.selectedDevice?.name ?? "Unavailable"
    guard state.isAutoSelected else { return deviceName }
    return "Auto, \(deviceName)"
  }
}
