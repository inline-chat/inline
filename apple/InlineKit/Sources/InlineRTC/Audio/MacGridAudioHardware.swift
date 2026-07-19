#if os(macOS)
import CoreAudio
import Foundation

struct MacGridAudioDevice: Equatable, Sendable {
  let id: AudioDeviceID
  let uid: String
  let name: String
  let hasInput: Bool
  let hasOutput: Bool
  let sampleRate: Double
  let bufferFrameSize: UInt32
  let transport: UInt32
}

struct MacGridAudioCatalogSnapshot: Equatable, Sendable {
  let devices: [MacGridAudioDevice]
  let defaultInputID: AudioDeviceID?
  let defaultOutputID: AudioDeviceID?
  let epoch: UInt64

  var inputs: [MacGridAudioDevice] { devices.filter(\.hasInput) }
  var outputs: [MacGridAudioDevice] { devices.filter(\.hasOutput) }

  var defaultInput: MacGridAudioDevice? {
    devices.first { $0.id == defaultInputID && $0.hasInput }
  }

  var defaultOutput: MacGridAudioDevice? {
    devices.first { $0.id == defaultOutputID && $0.hasOutput }
  }
}

enum MacGridAudioDeviceVisibility {
  /// AVFAudio creates these per-process while adapting an engine to the
  /// current default routes. They are implementation details whose IDs churn
  /// during a hardware switch, not devices a person can intentionally choose.
  private static let processPrivateAggregatePrefix = "CADefaultDeviceAggregate-"

  static func isUserSelectable(uid: String, name: String) -> Bool {
    !uid.hasPrefix(processPrivateAggregatePrefix) &&
      !name.hasPrefix(processPrivateAggregatePrefix)
  }
}

enum MacGridCoreAudioError: LocalizedError, Sendable {
  case status(OSStatus, operation: String)
  case unavailable(String)

  var errorDescription: String? {
    switch self {
    case let .status(status, operation):
      "\(operation) failed (Core Audio \(status))."
    case let .unavailable(message):
      message
    }
  }
}

func checkMacGridAudioStatus(_ status: OSStatus, _ operation: String) throws {
  guard status == noErr else {
    throw MacGridCoreAudioError.status(status, operation: operation)
  }
}

/// Process-wide Core Audio catalog. It observes only hardware facts; the
/// active audio driver owns selection policy and stream lifecycle.
final class MacGridAudioDeviceCatalog: @unchecked Sendable {
  let updates: AsyncStream<MacGridAudioCatalogSnapshot>

  private let updateContinuation: AsyncStream<MacGridAudioCatalogSnapshot>.Continuation
  private let queue = DispatchQueue(label: "chat.inline.grid.audio.catalog")
  private var listening = false
  private var epoch: UInt64 = 0

  init() {
    let stream = AsyncStream.makeStream(
      of: MacGridAudioCatalogSnapshot.self,
      bufferingPolicy: .bufferingNewest(1)
    )
    updates = stream.stream
    updateContinuation = stream.continuation
  }

  deinit {
    stop()
    updateContinuation.finish()
  }

  func start() {
    queue.async { [weak self] in
      guard let self, !listening else { return }
      listening = true
      addListeners()
      refreshOnQueue()
    }
  }

  func stop() {
    queue.sync {
      guard listening else { return }
      listening = false
      removeListeners()
    }
  }

  func snapshot() async throws -> MacGridAudioCatalogSnapshot {
    try await withCheckedThrowingContinuation { continuation in
      queue.async { [weak self] in
        guard let self else {
          continuation.resume(throwing: CancellationError())
          return
        }
        do {
          continuation.resume(returning: try makeSnapshot())
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }

  private let listener: AudioObjectPropertyListenerProc = { _, _, _, clientData in
    guard let clientData else { return noErr }
    let catalog = Unmanaged<MacGridAudioDeviceCatalog>.fromOpaque(clientData).takeUnretainedValue()
    catalog.queue.async { [weak catalog] in catalog?.refreshOnQueue() }
    return noErr
  }

  private func refreshOnQueue() {
    guard listening else { return }
    do {
      updateContinuation.yield(try makeSnapshot())
    } catch {
      // A property can disappear mid-enumeration. The next Core Audio change
      // produces another refresh; retaining the last snapshot is safer than
      // publishing a fabricated empty catalog.
    }
  }

  private func makeSnapshot() throws -> MacGridAudioCatalogSnapshot {
    epoch &+= 1
    let system = AudioObjectID(kAudioObjectSystemObject)
    let defaultInput = try? MacGridCoreAudioProperty.value(
      AudioDeviceID.self,
      object: system,
      selector: kAudioHardwarePropertyDefaultInputDevice
    )
    let defaultOutput = try? MacGridCoreAudioProperty.value(
      AudioDeviceID.self,
      object: system,
      selector: kAudioHardwarePropertyDefaultOutputDevice
    )
    let ids = try MacGridCoreAudioProperty.array(
      AudioDeviceID.self,
      object: system,
      selector: kAudioHardwarePropertyDevices
    )
    let devices = ids.compactMap { id -> MacGridAudioDevice? in
      guard let uid = try? MacGridCoreAudioProperty.string(
        object: id,
        selector: kAudioDevicePropertyDeviceUID
      ), let name = try? MacGridCoreAudioProperty.string(
        object: id,
        selector: kAudioObjectPropertyName
      ) else { return nil }
      guard MacGridAudioDeviceVisibility.isUserSelectable(uid: uid, name: name) else {
        return nil
      }
      let hasInput = MacGridCoreAudioProperty.exists(
        object: id,
        selector: kAudioDevicePropertyStreams,
        scope: kAudioDevicePropertyScopeInput
      )
      let hasOutput = MacGridCoreAudioProperty.exists(
        object: id,
        selector: kAudioDevicePropertyStreams,
        scope: kAudioDevicePropertyScopeOutput
      )
      guard hasInput || hasOutput else { return nil }
      return MacGridAudioDevice(
        id: id,
        uid: uid,
        name: name,
        hasInput: hasInput,
        hasOutput: hasOutput,
        sampleRate: (try? MacGridCoreAudioProperty.value(
          Float64.self,
          object: id,
          selector: kAudioDevicePropertyNominalSampleRate
        )) ?? 48_000,
        bufferFrameSize: (try? MacGridCoreAudioProperty.value(
          UInt32.self,
          object: id,
          selector: kAudioDevicePropertyBufferFrameSize
        )) ?? 512,
        transport: (try? MacGridCoreAudioProperty.value(
          UInt32.self,
          object: id,
          selector: kAudioDevicePropertyTransportType
        )) ?? 0
      )
    }
    .sorted { lhs, rhs in
      lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }
    return MacGridAudioCatalogSnapshot(
      devices: devices,
      defaultInputID: defaultInput,
      defaultOutputID: defaultOutput,
      epoch: epoch
    )
  }

  private func addListeners() {
    let pointer = Unmanaged.passUnretained(self).toOpaque()
    for selector in Self.observedSelectors {
      var address = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
      )
      AudioObjectAddPropertyListener(
        AudioObjectID(kAudioObjectSystemObject),
        &address,
        listener,
        pointer
      )
    }
  }

  private func removeListeners() {
    let pointer = Unmanaged.passUnretained(self).toOpaque()
    for selector in Self.observedSelectors {
      var address = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
      )
      AudioObjectRemovePropertyListener(
        AudioObjectID(kAudioObjectSystemObject),
        &address,
        listener,
        pointer
      )
    }
  }

  private static let observedSelectors: [AudioObjectPropertySelector] = [
    kAudioHardwarePropertyDevices,
    kAudioHardwarePropertyDefaultInputDevice,
    kAudioHardwarePropertyDefaultOutputDevice,
  ]
}

private enum MacGridCoreAudioProperty {
  static func value<T>(
    _ type: T.Type,
    object: AudioObjectID,
    selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
  ) throws -> T {
    var address = AudioObjectPropertyAddress(
      mSelector: selector,
      mScope: scope,
      mElement: kAudioObjectPropertyElementMain
    )
    let result = UnsafeMutablePointer<T>.allocate(capacity: 1)
    defer { result.deallocate() }
    var size = UInt32(MemoryLayout<T>.size)
    try checkMacGridAudioStatus(
      AudioObjectGetPropertyData(object, &address, 0, nil, &size, result),
      "read property \(selector)"
    )
    return result.move()
  }

  static func array<T>(
    _ type: T.Type,
    object: AudioObjectID,
    selector: AudioObjectPropertySelector
  ) throws -> [T] {
    var address = AudioObjectPropertyAddress(
      mSelector: selector,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var size: UInt32 = 0
    try checkMacGridAudioStatus(
      AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size),
      "size property \(selector)"
    )
    guard size > 0 else { return [] }
    let count = Int(size) / MemoryLayout<T>.size
    let storage = UnsafeMutablePointer<T>.allocate(capacity: count)
    defer { storage.deallocate() }
    try checkMacGridAudioStatus(
      AudioObjectGetPropertyData(object, &address, 0, nil, &size, storage),
      "read property array \(selector)"
    )
    return Array(UnsafeBufferPointer(start: storage, count: count))
  }

  static func string(
    object: AudioObjectID,
    selector: AudioObjectPropertySelector
  ) throws -> String {
    var address = AudioObjectPropertyAddress(
      mSelector: selector,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    try checkMacGridAudioStatus(
      AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value),
      "read string property \(selector)"
    )
    guard let value else {
      throw MacGridCoreAudioError.unavailable("Core Audio device has no UID.")
    }
    return value.takeUnretainedValue() as String
  }

  static func exists(
    object: AudioObjectID,
    selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope
  ) -> Bool {
    var address = AudioObjectPropertyAddress(
      mSelector: selector,
      mScope: scope,
      mElement: kAudioObjectPropertyElementMain
    )
    var size: UInt32 = 0
    return AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr && size > 0
  }
}
#endif
