#if os(macOS)
import Foundation
import LiveKit

struct MacGridWebRTCInputDevice: Equatable, Sendable {
  let id: String
  let name: String
}

struct MacGridWebRTCInputSelection: Equatable, Sendable {
  let webRTCDevice: MacGridWebRTCInputDevice
  let physicalDevice: MacGridAudioDevice
  let catalog: MacGridAudioCatalogSnapshot
}

/// The narrow WebRTC device boundary used by Grid.
///
/// Route policy and durable device identity stay in InlineRTC. This boundary
/// performs only the final selection against WebRTC's post-transport device
/// inventory, which also makes policy transactions testable without audio
/// hardware or a running LiveKit room.
protocol MacGridWebRTCInputDeviceAccess: Sendable {
  func selectInputDevice(id: String) throws -> MacGridWebRTCInputDevice
}

struct LiveKitMacGridWebRTCInputDeviceAccess: MacGridWebRTCInputDeviceAccess {
  func selectInputDevice(id: String) throws -> MacGridWebRTCInputDevice {
    let manager = AudioManager.shared
    let devices = manager.inputDevices
    guard let device = devices.first(where: { $0.deviceId == id }) else {
      throw MacGridWebRTCInputDeviceError.inventoryDidNotConverge(
        requestedID: id,
        availableIDs: devices.map(\.deviceId),
        attempts: 1
      )
    }

    try manager.set(inputDevice: device)
    return MacGridWebRTCInputDevice(id: device.deviceId, name: device.name)
  }
}

struct MacGridWebRTCInputDeviceController: Sendable {
  typealias Sleep = @Sendable (Duration) async throws -> Void

  private let access: any MacGridWebRTCInputDeviceAccess
  private let maximumAttempts: Int
  private let retryDelay: Duration
  private let sleep: Sleep

  init(
    access: any MacGridWebRTCInputDeviceAccess = LiveKitMacGridWebRTCInputDeviceAccess(),
    maximumAttempts: Int = 36,
    retryDelay: Duration = .milliseconds(100),
    sleep: @escaping Sleep = { try await Task.sleep(for: $0) }
  ) {
    self.access = access
    self.maximumAttempts = max(1, maximumAttempts)
    self.retryDelay = retryDelay
    self.sleep = sleep
  }

  @discardableResult
  func select(
    _ target: AudioInputRouteTarget,
    in snapshot: MacGridAudioCatalogSnapshot
  ) async throws -> MacGridWebRTCInputDevice {
    try await select(target, snapshot: { snapshot }).webRTCDevice
  }

  func select(
    _ target: AudioInputRouteTarget,
    snapshot: @escaping @Sendable () async throws -> MacGridAudioCatalogSnapshot
  ) async throws -> MacGridWebRTCInputSelection {
    var availableIDs: [String] = []
    var requestedID = MacGridPlatformAudioDeviceResolver.defaultDeviceID
    for attempt in 1 ... maximumAttempts {
      let currentCatalog = try await snapshot()
      let physicalDevice = try MacGridPlatformAudioDeviceResolver.inputDevice(
        for: target,
        in: currentCatalog
      )
      requestedID = try MacGridPlatformAudioDeviceResolver.platformInputDeviceID(
        for: target,
        in: currentCatalog
      )
      do {
        return MacGridWebRTCInputSelection(
          webRTCDevice: try access.selectInputDevice(id: requestedID),
          physicalDevice: physicalDevice,
          catalog: currentCatalog
        )
      } catch let error as MacGridWebRTCInputDeviceError {
        availableIDs = error.availableIDs
        guard attempt < maximumAttempts else {
          throw MacGridWebRTCInputDeviceError.inventoryDidNotConverge(
            requestedID: requestedID,
            availableIDs: availableIDs,
            attempts: attempt
          )
        }
        try await sleep(retryDelay)
      }
    }

    throw MacGridWebRTCInputDeviceError.inventoryDidNotConverge(
      requestedID: requestedID,
      availableIDs: availableIDs,
      attempts: maximumAttempts
    )
  }
}

enum MacGridWebRTCInputDeviceError: LocalizedError, Sendable, CustomStringConvertible {
  case inventoryDidNotConverge(
    requestedID: String,
    availableIDs: [String],
    attempts: Int
  )

  var requestedID: String {
    switch self {
    case let .inventoryDidNotConverge(requestedID, _, _): requestedID
    }
  }

  var availableIDs: [String] {
    switch self {
    case let .inventoryDidNotConverge(_, availableIDs, _): availableIDs
    }
  }

  var attempts: Int {
    switch self {
    case let .inventoryDidNotConverge(_, _, attempts): attempts
    }
  }

  var errorDescription: String? {
    "WebRTC's microphone list did not settle after an audio-device change."
  }

  var description: String {
    let route = requestedID == MacGridPlatformAudioDeviceResolver.defaultDeviceID
      ? "automatic"
      : "explicit"
    return "WebRTC microphone inventory did not converge "
      + "(route=\(route), available_count=\(availableIDs.count), attempts=\(attempts))."
  }
}
#endif
