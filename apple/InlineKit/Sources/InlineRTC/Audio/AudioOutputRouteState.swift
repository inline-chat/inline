import Foundation

/// Physical fields whose change requires rebuilding an AUHAL output even when
/// the durable device UID is unchanged (notably Bluetooth profile changes).
struct AudioOutputRouteFingerprint: Equatable, Sendable {
  let sampleRate: Double
  let channelCount: UInt32
  let bytesPerPacket: UInt32
  let framesPerPacket: UInt32
  let bytesPerFrame: UInt32
  let bitsPerChannel: UInt32
  let formatID: UInt32
  let formatFlags: UInt32
  let bufferFrameSize: UInt32
  let transport: UInt32
  let isAlive: Bool
}

struct AudioOutputDeviceInventory: Equatable, Sendable {
  let automaticDeviceID: String?
  let automaticDeviceName: String
  let devices: [AudioOutputDeviceDescriptor]
  let routeFingerprints: [String: AudioOutputRouteFingerprint]
  let routeEpoch: UInt64

  func resolve(_ selection: AudioOutputSelection) -> AudioOutputRouteResolution {
    switch selection {
    case .automatic:
      return AudioOutputRouteResolution(
        selection: selection,
        target: .automatic,
        activeDeviceID: automaticDeviceID,
        activeDeviceName: automaticDeviceName,
        isFallingBackToAutomatic: false,
        routeFingerprint: automaticDeviceID.flatMap { routeFingerprints[$0] }
      )
    case .device:
      if let id = selection.resolvedDeviceID(in: devices),
         let device = devices.first(where: { $0.id == id }) {
        return AudioOutputRouteResolution(
          selection: selection,
          target: .device(id: device.id, name: device.name),
          activeDeviceID: device.id,
          activeDeviceName: device.name,
          isFallingBackToAutomatic: false,
          routeFingerprint: routeFingerprints[device.id]
        )
      }
      return AudioOutputRouteResolution(
        selection: selection,
        target: .automatic,
        activeDeviceID: automaticDeviceID,
        activeDeviceName: automaticDeviceName,
        isFallingBackToAutomatic: true,
        routeFingerprint: automaticDeviceID.flatMap { routeFingerprints[$0] }
      )
    }
  }

  func snapshot(resolving selection: AudioOutputSelection) -> AudioOutputDeviceSnapshot {
    AudioOutputDeviceSnapshot(
      automaticDeviceID: automaticDeviceID,
      automaticDeviceName: automaticDeviceName,
      devices: devices,
      resolvedOutput: resolve(selection).publicValue,
      routeEpoch: routeEpoch
    )
  }
}

enum AudioOutputRouteTarget: Equatable, Sendable {
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

struct AudioOutputRouteResolution: Equatable, Sendable {
  let selection: AudioOutputSelection
  let target: AudioOutputRouteTarget
  let activeDeviceID: String?
  let activeDeviceName: String
  let isFallingBackToAutomatic: Bool
  let routeFingerprint: AudioOutputRouteFingerprint?

  var publicValue: ResolvedAudioOutput {
    ResolvedAudioOutput(
      selection: selection,
      activeDeviceID: activeDeviceID,
      activeDeviceName: activeDeviceName,
      isFallingBackToAutomatic: isFallingBackToAutomatic
    )
  }
}

struct AudioOutputRouteState: Equatable, Sendable {
  private(set) var desiredSelection: AudioOutputSelection = .automatic
  private(set) var inventory: AudioOutputDeviceInventory?
  private(set) var appliedTarget: AudioOutputRouteTarget?
  private(set) var appliedResolution: AudioOutputRouteResolution?
  private(set) var failedExplicitTarget: AudioOutputRouteTarget?
  private(set) var automaticRouteFailed = false
  private(set) var revision: UInt64 = 0

  mutating func setSelection(_ selection: AudioOutputSelection) {
    guard desiredSelection != selection else { return }
    desiredSelection = selection
    failedExplicitTarget = nil
    automaticRouteFailed = false
    revision &+= 1
  }

  mutating func observe(_ inventory: AudioOutputDeviceInventory) {
    guard self.inventory != inventory else { return }
    if case let .device(id, _)? = failedExplicitTarget {
      let wasAvailable = self.inventory?.devices.contains(where: { $0.id == id }) == true
      let isAvailable = inventory.devices.contains(where: { $0.id == id })
      let previousFingerprint = self.inventory?.routeFingerprints[id]
      let currentFingerprint = inventory.routeFingerprints[id]
      if (!wasAvailable && isAvailable)
        || (isAvailable && previousFingerprint != currentFingerprint) {
        failedExplicitTarget = nil
      }
    }
    self.inventory = inventory
    revision &+= 1
  }

  var desiredResolution: AudioOutputRouteResolution? {
    guard let inventory else { return nil }
    let resolved = inventory.resolve(desiredSelection)
    guard case .device = resolved.target, resolved.target == failedExplicitTarget else {
      return resolved
    }
    return AudioOutputRouteResolution(
      selection: desiredSelection,
      target: .automatic,
      activeDeviceID: inventory.automaticDeviceID,
      activeDeviceName: inventory.automaticDeviceName,
      isFallingBackToAutomatic: true,
      routeFingerprint: inventory.automaticDeviceID.flatMap {
        inventory.routeFingerprints[$0]
      }
    )
  }

  var needsRouteTransaction: Bool {
    guard let desiredResolution else { return false }
    guard appliedTarget == desiredResolution.target else { return true }
    return appliedResolution?.activeDeviceID != desiredResolution.activeDeviceID
      || appliedResolution?.routeFingerprint != desiredResolution.routeFingerprint
  }

  mutating func commitResolvedMetadataIfRouteMatches() {
    guard let desiredResolution,
          desiredResolution.target == appliedTarget,
          !needsRouteTransaction
    else { return }
    appliedResolution = desiredResolution
  }

  mutating func routeTransactionSucceeded(_ resolution: AudioOutputRouteResolution) {
    appliedTarget = resolution.target
    appliedResolution = resolution
    if case .automatic = resolution.target {
      automaticRouteFailed = false
    } else if resolution.target == failedExplicitTarget {
      failedExplicitTarget = nil
    }
  }

  mutating func routeTransactionFailed(_ resolution: AudioOutputRouteResolution) {
    switch resolution.target {
    case .automatic:
      automaticRouteFailed = true
    case .device:
      failedExplicitTarget = resolution.target
    }
    // AUHAL owns rollback and retains the previous direction whenever that is
    // possible. Keep the last verified commit until another transaction is
    // verified; projecting the failed desired route would be less truthful.
    // Runtime health separately exposes an incomplete rollback as unhealthy.
    revision &+= 1
  }

  /// AUHAL verified that the previous output remains healthy after a
  /// transition-class failure. Preserve both that applied truth and the
  /// original preference so a capped retry can honor the selected route.
  mutating func routeTransactionDeferredAfterTransientFailure(
    _: AudioOutputRouteResolution
  ) {
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

  var snapshot: AudioOutputDeviceSnapshot? {
    guard let inventory else { return nil }
    let resolved = appliedResolution ?? desiredResolution ?? inventory.resolve(desiredSelection)
    let publicResolution: ResolvedAudioOutput
    if resolved.selection != desiredSelection {
      publicResolution = ResolvedAudioOutput(
        selection: desiredSelection,
        activeDeviceID: resolved.activeDeviceID,
        activeDeviceName: resolved.activeDeviceName,
        isFallingBackToAutomatic: {
          if case .device = desiredSelection { return true }
          return resolved.isFallingBackToAutomatic
        }()
      )
    } else {
      publicResolution = resolved.publicValue
    }
    return AudioOutputDeviceSnapshot(
      automaticDeviceID: inventory.automaticDeviceID,
      automaticDeviceName: inventory.automaticDeviceName,
      devices: inventory.devices,
      resolvedOutput: publicResolution,
      routeEpoch: inventory.routeEpoch
    )
  }
}
