#if os(macOS)
import CoreAudio
import Foundation

struct MacGridAudioOutputRouteSignature: Equatable {
  let deviceID: AudioDeviceID
  let deviceUID: String
  let sampleRate: Double
  let channelCount: UInt32
  let bytesPerPacket: UInt32
  let framesPerPacket: UInt32
  let bytesPerFrame: UInt32
  let bitsPerChannel: UInt32
  let formatID: AudioFormatID
  let formatFlags: AudioFormatFlags
  let bufferFrameSize: UInt32
  let transport: UInt32
  let isAlive: Bool
}

struct MacGridAudioInputRouteSignature: Equatable {
  let deviceID: AudioDeviceID
  let deviceUID: String
  let sampleRate: Double
  let channelCount: UInt32
  let bytesPerPacket: UInt32
  let framesPerPacket: UInt32
  let bytesPerFrame: UInt32
  let bitsPerChannel: UInt32
  let formatID: AudioFormatID
  let formatFlags: AudioFormatFlags
  let bufferFrameSize: UInt32
  let transport: UInt32
  let isAlive: Bool
}

extension MacGridAudioDevice {
  var inputRouteSignature: MacGridAudioInputRouteSignature? {
    guard hasInput, let format = inputStreamFormat else { return nil }
    return MacGridAudioInputRouteSignature(
      deviceID: id,
      deviceUID: uid,
      sampleRate: format.sampleRate,
      channelCount: format.channelCount,
      bytesPerPacket: format.bytesPerPacket,
      framesPerPacket: format.framesPerPacket,
      bytesPerFrame: format.bytesPerFrame,
      bitsPerChannel: format.bitsPerChannel,
      formatID: format.formatID,
      formatFlags: format.formatFlags,
      bufferFrameSize: bufferFrameSize,
      transport: transport,
      isAlive: isAlive
    )
  }

  var outputRouteSignature: MacGridAudioOutputRouteSignature? {
    guard hasOutput, let format = outputStreamFormat else { return nil }
    return MacGridAudioOutputRouteSignature(
      deviceID: id,
      deviceUID: uid,
      sampleRate: format.sampleRate,
      channelCount: format.channelCount,
      bytesPerPacket: format.bytesPerPacket,
      framesPerPacket: format.framesPerPacket,
      bytesPerFrame: format.bytesPerFrame,
      bitsPerChannel: format.bitsPerChannel,
      formatID: format.formatID,
      formatFlags: format.formatFlags,
      bufferFrameSize: bufferFrameSize,
      transport: transport,
      isAlive: isAlive
    )
  }
}

extension MacGridAudioCatalogSnapshot {
  var defaultOutputRouteSignature: MacGridAudioOutputRouteSignature? {
    defaultOutput?.outputRouteSignature
  }

  func inputRouteSignature(forUID uid: String?) -> MacGridAudioInputRouteSignature? {
    guard let uid else { return nil }
    return inputs.first { $0.uid == uid }?.inputRouteSignature
  }

  func outputRouteSignature(forUID uid: String?) -> MacGridAudioOutputRouteSignature? {
    guard let uid else { return nil }
    return outputs.first { $0.uid == uid }?.outputRouteSignature
  }
}

enum MacGridAudioRouteTransitionPolicy {
  static func inputIsUsable(_ input: MacGridAudioDevice) -> Bool {
    guard input.hasInput,
          input.isAlive,
          let format = input.inputStreamFormat
    else { return false }

    return format.sampleRate > 0
      && format.channelCount > 0
      && input.bufferFrameSize > 0
  }

  static func requiresCoordinatedPlayout(
    previousInputUID _: String?,
    nextInputUID _: String,
    in _: MacGridAudioCatalogSnapshot
  ) -> Bool {
    // The custom WebRTC device owns independent AUHAL input and output units.
    // Replacing capture therefore never requires tearing down physical
    // playout. Bluetooth output profile churn is reconciled independently by
    // the output settle transaction.
    false
  }

  static func outputIsUsable(_ output: MacGridAudioDevice) -> Bool {
    guard output.hasOutput, output.isAlive else { return false }
    let sampleRate = output.outputStreamFormat?.sampleRate ?? output.sampleRate
    let channelCount = output.outputStreamFormat?.channelCount ?? 0
    return sampleRate > 0 && channelCount > 0 && output.bufferFrameSize > 0
  }

  static func outputIsUsable(in snapshot: MacGridAudioCatalogSnapshot) -> Bool {
    guard let output = snapshot.defaultOutput else { return false }
    return outputIsUsable(output)
  }
}

/// Idle input health is physical route state, not control-plane preparation
/// state. WebRTC can stop its native recording demand without calling back
/// through the actor that last prepared capture, so that actor-local value is
/// deliberately absent from this policy.
struct MacGridAUHALIdleInputRouteHealthState {
  let nativeRecordingDemanded: Bool
  let isRecording: Bool
  let expectedUID: String?
  let selectedUID: String?
  let activeUID: String?
  let activeSignature: MacGridAudioInputRouteSignature?
  let activeDeviceReadbackVerified: Bool?
  let lastControlFailure: String?
}

enum MacGridAUHALIdleInputRouteHealthPolicy {
  static func isValid(
    _ state: MacGridAUHALIdleInputRouteHealthState,
    catalogInput: MacGridAudioDevice?
  ) -> Bool {
    guard !state.nativeRecordingDemanded,
          !state.isRecording,
          state.lastControlFailure == nil,
          let expectedUID = state.expectedUID,
          state.selectedUID == expectedUID,
          let catalogInput,
          catalogInput.uid == expectedUID,
          MacGridAudioRouteTransitionPolicy.inputIsUsable(catalogInput)
    else { return false }

    // A selected route can be healthy before WebRTC initializes its physical
    // direction. If a stopped direction is retained, however, its direct
    // AudioUnit readback and physical format must still match the catalog.
    guard let activeUID = state.activeUID else { return true }
    return activeUID == expectedUID
      && state.activeDeviceReadbackVerified == true
      && state.activeSignature == catalogInput.inputRouteSignature
  }
}

struct MacGridAudioOutputSettleMonitor {
  private let target: AudioOutputRouteTarget
  private let requiredStableSamples: Int
  private var previousSignature: MacGridAudioOutputRouteSignature?
  private var stableSamples = 0

  init(
    target: AudioOutputRouteTarget = .automatic,
    requiredStableSamples: Int = 3
  ) {
    self.target = target
    self.requiredStableSamples = requiredStableSamples
  }

  mutating func observe(_ snapshot: MacGridAudioCatalogSnapshot) -> Bool {
    let output = try? MacGridPlatformAudioDeviceResolver.outputDevice(
      for: target,
      in: snapshot
    )
    let signature = output?.outputRouteSignature
    guard let output,
          MacGridAudioRouteTransitionPolicy.outputIsUsable(output)
    else {
      previousSignature = signature
      stableSamples = 0
      return false
    }
    if signature == previousSignature {
      stableSamples += 1
    } else {
      previousSignature = signature
      stableSamples = 1
    }
    return stableSamples >= requiredStableSamples
  }
}

struct MacGridAudioInputSettleMonitor {
  private let target: AudioInputRouteTarget
  private let expectedUID: String
  private let requiredStableSamples: Int
  private var previousSignature: MacGridAudioInputRouteSignature?
  private var stableSamples = 0

  init(
    target: AudioInputRouteTarget,
    expectedUID: String,
    requiredStableSamples: Int = 3
  ) {
    self.target = target
    self.expectedUID = expectedUID
    self.requiredStableSamples = max(requiredStableSamples, 1)
  }

  mutating func observe(_ snapshot: MacGridAudioCatalogSnapshot) -> Bool {
    let input = try? MacGridPlatformAudioDeviceResolver.inputDevice(
      for: target,
      in: snapshot
    )
    let signature = input?.inputRouteSignature
    guard let input,
          input.uid == expectedUID,
          MacGridAudioRouteTransitionPolicy.inputIsUsable(input)
    else {
      previousSignature = signature
      stableSamples = 0
      return false
    }
    if signature == previousSignature {
      stableSamples += 1
    } else {
      previousSignature = signature
      stableSamples = 1
    }
    return stableSamples >= requiredStableSamples
  }
}

/// Requires the physical callback counter to advance across independently
/// sampled health reads. Re-reading one fresh callback is not evidence that
/// the realtime stream survived device startup or route replacement.
struct MacGridAudioCallbackProgressMonitor {
  private let requiredAdvances: Int
  private var previousCallbackCount: UInt64?
  private var consecutiveAdvances = 0

  init(
    baselineCallbackCount: UInt64?,
    requiredAdvances: Int = 2
  ) {
    previousCallbackCount = baselineCallbackCount
    self.requiredAdvances = max(requiredAdvances, 1)
  }

  mutating func observe(
    callbackCount: UInt64?,
    isRouteValid: Bool
  ) -> Bool {
    defer { previousCallbackCount = callbackCount }
    guard isRouteValid,
          let callbackCount,
          let previousCallbackCount,
          callbackCount > previousCallbackCount
    else {
      consecutiveAdvances = 0
      return false
    }
    consecutiveAdvances += 1
    return consecutiveAdvances >= requiredAdvances
  }
}

struct MacGridAudioOutputSettleResult {
  let snapshot: MacGridAudioCatalogSnapshot
  let timedOut: Bool

  func requireCompatibleOutput() throws -> MacGridAudioCatalogSnapshot {
    guard !timedOut else {
      throw MacGridAudioOutputSettleError.incompatibleOutputTimedOut
    }
    return snapshot
  }
}

enum MacGridAudioOutputSettleError: LocalizedError {
  case incompatibleOutputTimedOut

  var errorDescription: String? {
    "The output route did not converge to a compatible format before the route transaction deadline."
  }
}

struct MacGridAudioOutputRouteSettler {
  private let catalog: MacGridAudioDeviceCatalog
  private let pollInterval: Duration
  private let timeout: Duration

  init(
    catalog: MacGridAudioDeviceCatalog,
    pollInterval: Duration = .milliseconds(100),
    timeout: Duration = .milliseconds(3_500)
  ) {
    self.catalog = catalog
    self.pollInterval = pollInterval
    self.timeout = timeout
  }

  func waitForCompatibleOutput(
    target: AudioOutputRouteTarget = .automatic,
    requiredStableSamples: Int = 3
  ) async throws -> MacGridAudioOutputSettleResult {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    var monitor = MacGridAudioOutputSettleMonitor(
      target: target,
      requiredStableSamples: requiredStableSamples
    )
    var latest = try await catalog.snapshot()

    while true {
      try Task.checkCancellation()
      if monitor.observe(latest) {
        return MacGridAudioOutputSettleResult(snapshot: latest, timedOut: false)
      }
      guard clock.now < deadline else {
        return MacGridAudioOutputSettleResult(snapshot: latest, timedOut: true)
      }
      try await Task.sleep(for: pollInterval)
      latest = try await catalog.snapshot()
    }
  }
}
#endif
