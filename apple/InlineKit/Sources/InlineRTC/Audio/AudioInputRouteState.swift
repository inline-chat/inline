import Foundation

/// A backend-independent inventory. The default route is described by the
/// physical device currently behind it, while selection keeps `automatic` as
/// policy rather than turning it into a writable device identifier.
struct AudioInputDeviceInventory: Equatable, Sendable {
  let automaticDeviceID: String?
  let automaticDeviceName: String
  let devices: [AudioInputDeviceDescriptor]
  let routeEpoch: UInt64

  func resolve(_ selection: AudioInputSelection) -> AudioInputRouteResolution {
    switch selection {
    case .automatic:
      return AudioInputRouteResolution(
        selection: selection,
        target: .automatic,
        activeDeviceID: automaticDeviceID,
        activeDeviceName: automaticDeviceName,
        isFallingBackToAutomatic: false
      )

    case .device:
      if let id = selection.resolvedDeviceID(in: devices),
         let device = devices.first(where: { $0.id == id }) {
        return AudioInputRouteResolution(
          selection: selection,
          target: .device(id: device.id, name: device.name),
          activeDeviceID: device.id,
          activeDeviceName: device.name,
          isFallingBackToAutomatic: false
        )
      }
      return AudioInputRouteResolution(
        selection: selection,
        target: .automatic,
        activeDeviceID: automaticDeviceID,
        activeDeviceName: automaticDeviceName,
        isFallingBackToAutomatic: true
      )
    }
  }

  func snapshot(resolving selection: AudioInputSelection) -> AudioInputDeviceSnapshot {
    let resolution = resolve(selection)
    return AudioInputDeviceSnapshot(
      automaticDeviceID: automaticDeviceID,
      automaticDeviceName: automaticDeviceName,
      devices: devices,
      resolvedInput: resolution.publicValue,
      routeEpoch: routeEpoch
    )
  }
}

/// The only route values a backend can receive. `automatic` is deliberately a
/// separate operation; a synthetic `default` ID can never escape as a device.
enum AudioInputRouteTarget: Equatable, Sendable {
  case automatic
  case device(id: String, name: String)

  var logDescription: String {
    switch self {
    case .automatic: "automatic"
    case .device: "explicit"
    }
  }

  static func == (lhs: Self, rhs: Self) -> Bool {
    switch (lhs, rhs) {
    case (.automatic, .automatic): true
    case let (.device(lhsID, _), .device(rhsID, _)): lhsID == rhsID
    default: false
    }
  }
}

struct AudioInputRouteResolution: Equatable, Sendable {
  let selection: AudioInputSelection
  let target: AudioInputRouteTarget
  let activeDeviceID: String?
  let activeDeviceName: String
  let isFallingBackToAutomatic: Bool

  var publicValue: ResolvedAudioInput {
    ResolvedAudioInput(
      selection: selection,
      activeDeviceID: activeDeviceID,
      activeDeviceName: activeDeviceName,
      isFallingBackToAutomatic: isFallingBackToAutomatic
    )
  }
}

/// Pure state machine for input preference and applied route ownership.
/// Core Audio callbacks only replace inventory. They can request a route
/// transaction when the resolved target actually changes, but they cannot
/// directly mutate the audio engine or erase the user's preference.
struct AudioInputRouteState: Equatable, Sendable {
  private(set) var desiredSelection: AudioInputSelection = .automatic
  private(set) var inventory: AudioInputDeviceInventory?
  private(set) var appliedTarget: AudioInputRouteTarget?
  private(set) var appliedResolution: AudioInputRouteResolution?
  /// Keep the rejected explicit device independent from a rejected Auto
  /// fallback. A single `failedTarget` loses the explicit quarantine when the
  /// fallback also fails and makes resolution oscillate forever.
  private(set) var failedExplicitTarget: AudioInputRouteTarget?
  private(set) var automaticRouteFailed = false
  private(set) var revision: UInt64 = 0

  mutating func setSelection(_ selection: AudioInputSelection) {
    guard desiredSelection != selection else { return }
    desiredSelection = selection
    failedExplicitTarget = nil
    automaticRouteFailed = false
    revision &+= 1
  }

  mutating func observe(_ inventory: AudioInputDeviceInventory) {
    guard self.inventory != inventory else { return }
    if case let .device(id, _)? = failedExplicitTarget {
      let wasAvailable = self.inventory?.devices.contains(where: { $0.id == id }) == true
      let isAvailable = inventory.devices.contains(where: { $0.id == id })
      if !wasAvailable, isAvailable {
        failedExplicitTarget = nil
      }
    }
    self.inventory = inventory
    revision &+= 1
  }

  var desiredResolution: AudioInputRouteResolution? {
    guard let inventory else { return nil }
    let resolved = inventory.resolve(desiredSelection)
    guard case .device = resolved.target, resolved.target == failedExplicitTarget else {
      return resolved
    }
    return AudioInputRouteResolution(
      selection: desiredSelection,
      target: .automatic,
      activeDeviceID: inventory.automaticDeviceID,
      activeDeviceName: inventory.automaticDeviceName,
      isFallingBackToAutomatic: true
    )
  }

  var needsRouteTransaction: Bool {
    guard let desiredResolution else { return false }
    return appliedTarget != desiredResolution.target
  }

  /// Commits metadata when policy changes but the concrete route does not—for
  /// example choosing Auto while already using the physical system default.
  mutating func commitResolvedMetadataIfRouteMatches() {
    guard let desiredResolution, desiredResolution.target == appliedTarget else { return }
    appliedResolution = desiredResolution
  }

  /// Records what the backend actually applied even if newer user intent
  /// arrived while the transaction was running. The caller can immediately
  /// reconcile again from the new revision without lying about active route.
  mutating func routeTransactionSucceeded(_ resolution: AudioInputRouteResolution) {
    appliedTarget = resolution.target
    appliedResolution = resolution
    if case .automatic = resolution.target {
      automaticRouteFailed = false
    } else if resolution.target == failedExplicitTarget {
      failedExplicitTarget = nil
    }
  }

  /// Quarantines only the concrete route that failed. An explicit preference
  /// then resolves to Auto without being erased; an Auto failure has no hidden
  /// alternative and is retried only after explicit user/lifecycle intent.
  mutating func routeTransactionFailed(_ resolution: AudioInputRouteResolution) {
    switch resolution.target {
    case .automatic:
      automaticRouteFailed = true
    case .device:
      failedExplicitTarget = resolution.target
    }
    appliedTarget = nil
    appliedResolution = nil
    revision &+= 1
  }

  mutating func clearRouteFailure() {
    guard failedExplicitTarget != nil || automaticRouteFailed else { return }
    failedExplicitTarget = nil
    automaticRouteFailed = false
    revision &+= 1
  }

  mutating func assumeCurrentRouteUnknown() {
    appliedTarget = nil
    appliedResolution = nil
  }

  var snapshot: AudioInputDeviceSnapshot? {
    guard let inventory else { return nil }
    let resolved = appliedResolution ?? desiredResolution ?? inventory.resolve(desiredSelection)
    return AudioInputDeviceSnapshot(
      automaticDeviceID: inventory.automaticDeviceID,
      automaticDeviceName: inventory.automaticDeviceName,
      devices: inventory.devices,
      resolvedInput: resolved.publicValue,
      routeEpoch: inventory.routeEpoch
    )
  }
}
