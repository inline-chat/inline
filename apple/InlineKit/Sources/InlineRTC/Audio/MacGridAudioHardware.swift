#if os(macOS)
import CoreAudio
import Foundation

struct MacGridAudioStreamFormat: Equatable, Sendable {
  let sampleRate: Double
  let channelCount: UInt32
  let bytesPerPacket: UInt32
  let framesPerPacket: UInt32
  let bytesPerFrame: UInt32
  let bitsPerChannel: UInt32
  let formatID: AudioFormatID
  let formatFlags: AudioFormatFlags

  init(_ description: AudioStreamBasicDescription) {
    sampleRate = description.mSampleRate
    channelCount = description.mChannelsPerFrame
    bytesPerPacket = description.mBytesPerPacket
    framesPerPacket = description.mFramesPerPacket
    bytesPerFrame = description.mBytesPerFrame
    bitsPerChannel = description.mBitsPerChannel
    formatID = description.mFormatID
    formatFlags = description.mFormatFlags
  }
}

struct MacGridAudioDevice: Equatable, Sendable {
  let id: AudioDeviceID
  let uid: String
  let name: String
  let hasInput: Bool
  let hasOutput: Bool
  let sampleRate: Double
  let bufferFrameSize: UInt32
  let transport: UInt32
  let isAlive: Bool
  let inputStreamFormat: MacGridAudioStreamFormat?
  let outputStreamFormat: MacGridAudioStreamFormat?

  init(
    id: AudioDeviceID,
    uid: String,
    name: String,
    hasInput: Bool,
    hasOutput: Bool,
    sampleRate: Double,
    bufferFrameSize: UInt32,
    transport: UInt32,
    isAlive: Bool = true,
    inputStreamFormat: MacGridAudioStreamFormat? = nil,
    outputStreamFormat: MacGridAudioStreamFormat? = nil
  ) {
    self.id = id
    self.uid = uid
    self.name = name
    self.hasInput = hasInput
    self.hasOutput = hasOutput
    self.sampleRate = sampleRate
    self.bufferFrameSize = bufferFrameSize
    self.transport = transport
    self.isAlive = isAlive
    self.inputStreamFormat = inputStreamFormat
    self.outputStreamFormat = outputStreamFormat
  }

  var isBluetooth: Bool {
    transport == kAudioDeviceTransportTypeBluetooth
      || transport == kAudioDeviceTransportTypeBluetoothLE
  }
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

/// Physical HAL devices currently carrying this process's input/output IO.
/// Unlike the ADM selector, these IDs describe devices Core Audio has opened.
struct MacGridAudioProcessRouteSnapshot: Equatable, Sendable {
  let inputDeviceIDs: [AudioDeviceID]
  let outputDeviceIDs: [AudioDeviceID]
  let isRunningInput: Bool
  let isRunningOutput: Bool
}

enum MacGridAudioDeviceVisibility {
  /// AVFAudio creates these per-process while adapting an engine to the
  /// current default routes. They are implementation details whose IDs churn
  /// during a hardware switch, not devices a person can intentionally choose.
  private static let processPrivateAggregatePrefix = "CADefaultDeviceAggregate-"
  private static let gridPrivateAggregatePrefix = "org.webrtc.audioengine.aggregate."

  static func isUserSelectable(uid: String, name: String) -> Bool {
    !uid.hasPrefix(processPrivateAggregatePrefix) &&
      !name.hasPrefix(processPrivateAggregatePrefix) &&
      !uid.hasPrefix(gridPrivateAggregatePrefix)
  }
}

enum MacGridAudioProcessDeviceExpansion {
  /// Keep each process-facing device and append its active aggregate children.
  /// User-created aggregates can therefore still match their own durable UID,
  /// while Grid's hidden private aggregate resolves to the physical endpoints
  /// that actually carry capture and playout.
  static func expand(
    _ deviceIDs: [AudioDeviceID],
    activeSubdevices: (AudioDeviceID) -> [AudioDeviceID]
  ) -> [AudioDeviceID] {
    var seen = Set<AudioDeviceID>()
    var result: [AudioDeviceID] = []
    for deviceID in deviceIDs {
      for candidate in [deviceID] + activeSubdevices(deviceID)
      where candidate != kAudioObjectUnknown && seen.insert(candidate).inserted {
        result.append(candidate)
      }
    }
    return result
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
  private let queueSpecificKey = DispatchSpecificKey<UInt8>()
  private var listening = false
  private var epoch: UInt64 = 0
  private var deviceListenerAddresses: [AudioDeviceID: [AudioObjectPropertyAddress]] = [:]

  init() {
    queue.setSpecific(key: queueSpecificKey, value: 1)
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
      addSystemListeners()
      refreshOnQueue()
    }
  }

  func stop() {
    let stopOnQueue = { [self] in
      guard listening else { return }
      listening = false
      removeDeviceListeners()
      removeSystemListeners()
    }
    if DispatchQueue.getSpecific(key: queueSpecificKey) != nil {
      stopOnQueue()
    } else {
      queue.sync(execute: stopOnQueue)
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

  func processRouteSnapshot() async throws -> MacGridAudioProcessRouteSnapshot {
    try await withCheckedThrowingContinuation { continuation in
      queue.async { [weak self] in
        guard let self else {
          continuation.resume(throwing: CancellationError())
          return
        }
        do {
          continuation.resume(returning: try makeProcessRouteSnapshot())
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }

  private lazy var listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
    // Core Audio delivers this retained block on `queue`; the weak capture
    // remains safe even if a notification was already in flight when stop()
    // removed its registration.
    self?.refreshOnQueue()
  }

  private func refreshOnQueue() {
    guard listening else { return }
    do {
      epoch &+= 1
      let snapshot = try makeSnapshot()
      reconcileDeviceListeners(with: snapshot.devices)
      updateContinuation.yield(snapshot)
    } catch {
      // A property can disappear mid-enumeration. The next Core Audio change
      // produces another refresh; retaining the last snapshot is safer than
      // publishing a fabricated empty catalog.
    }
  }

  private func makeSnapshot() throws -> MacGridAudioCatalogSnapshot {
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
        )) ?? 0,
        bufferFrameSize: (try? MacGridCoreAudioProperty.value(
          UInt32.self,
          object: id,
          selector: kAudioDevicePropertyBufferFrameSize
        )) ?? 0,
        transport: (try? MacGridCoreAudioProperty.value(
          UInt32.self,
          object: id,
          selector: kAudioDevicePropertyTransportType
        )) ?? 0,
        isAlive: ((try? MacGridCoreAudioProperty.value(
          UInt32.self,
          object: id,
          selector: kAudioDevicePropertyDeviceIsAlive
        )) ?? 0) != 0,
        inputStreamFormat: hasInput
          ? try? MacGridCoreAudioProperty.streamFormat(
            object: id,
            scope: kAudioDevicePropertyScopeInput
          )
          : nil,
        outputStreamFormat: hasOutput
          ? try? MacGridCoreAudioProperty.streamFormat(
            object: id,
            scope: kAudioDevicePropertyScopeOutput
          )
          : nil
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

  private func makeProcessRouteSnapshot() throws -> MacGridAudioProcessRouteSnapshot {
    let system = AudioObjectID(kAudioObjectSystemObject)
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var processID = ProcessInfo.processInfo.processIdentifier
    var processObject = AudioObjectID(kAudioObjectUnknown)
    var resultSize = UInt32(MemoryLayout<AudioObjectID>.size)
    let qualifierSize = UInt32(MemoryLayout.size(ofValue: processID))
    let status = withUnsafePointer(to: &processID) { qualifier in
      AudioObjectGetPropertyData(
        system,
        &address,
        qualifierSize,
        qualifier,
        &resultSize,
        &processObject
      )
    }
    try checkMacGridAudioStatus(status, "resolve current Core Audio process")
    guard processObject != kAudioObjectUnknown else {
      return MacGridAudioProcessRouteSnapshot(
        inputDeviceIDs: [],
        outputDeviceIDs: [],
        isRunningInput: false,
        isRunningOutput: false
      )
    }

    let processInputDeviceIDs = try MacGridCoreAudioProperty.array(
      AudioDeviceID.self,
      object: processObject,
      selector: kAudioProcessPropertyDevices,
      scope: kAudioObjectPropertyScopeInput
    )
    let processOutputDeviceIDs = try MacGridCoreAudioProperty.array(
      AudioDeviceID.self,
      object: processObject,
      selector: kAudioProcessPropertyDevices,
      scope: kAudioObjectPropertyScopeOutput
    )
    let expandProcessDevices: ([AudioDeviceID]) -> [AudioDeviceID] = { deviceIDs in
      MacGridAudioProcessDeviceExpansion.expand(deviceIDs) { deviceID in
        (try? MacGridCoreAudioProperty.array(
          AudioDeviceID.self,
          object: deviceID,
          selector: kAudioAggregateDevicePropertyActiveSubDeviceList
        )) ?? []
      }
    }
    let inputDeviceIDs = expandProcessDevices(processInputDeviceIDs)
    let outputDeviceIDs = expandProcessDevices(processOutputDeviceIDs)
    let isRunningInput = try MacGridCoreAudioProperty.value(
      UInt32.self,
      object: processObject,
      selector: kAudioProcessPropertyIsRunningInput
    ) != 0
    let isRunningOutput = try MacGridCoreAudioProperty.value(
      UInt32.self,
      object: processObject,
      selector: kAudioProcessPropertyIsRunningOutput
    ) != 0
    return MacGridAudioProcessRouteSnapshot(
      inputDeviceIDs: inputDeviceIDs,
      outputDeviceIDs: outputDeviceIDs,
      isRunningInput: isRunningInput,
      isRunningOutput: isRunningOutput
    )
  }

  private func addSystemListeners() {
    for selector in Self.observedSelectors {
      var address = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
      )
      AudioObjectAddPropertyListenerBlock(
        AudioObjectID(kAudioObjectSystemObject),
        &address,
        queue,
        listener,
      )
    }
  }

  private func removeSystemListeners() {
    for selector in Self.observedSelectors {
      var address = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
      )
      AudioObjectRemovePropertyListenerBlock(
        AudioObjectID(kAudioObjectSystemObject),
        &address,
        queue,
        listener,
      )
    }
  }

  private func reconcileDeviceListeners(with devices: [MacGridAudioDevice]) {
    let deviceIDs = Set(devices.map(\.id))
    for deviceID in Array(deviceListenerAddresses.keys) where !deviceIDs.contains(deviceID) {
      removeDeviceListeners(for: deviceID)
    }
    for device in devices where deviceListenerAddresses[device.id] == nil {
      addDeviceListeners(for: device)
    }
  }

  private func addDeviceListeners(for device: MacGridAudioDevice) {
    let addresses = Self.observedAddresses(for: device).filter { address in
      var address = address
      return AudioObjectHasProperty(device.id, &address)
    }
    var installed: [AudioObjectPropertyAddress] = []
    for address in addresses {
      var address = address
      guard AudioObjectAddPropertyListenerBlock(
        device.id,
        &address,
        queue,
        listener
      ) == noErr else {
        continue
      }
      installed.append(address)
    }
    deviceListenerAddresses[device.id] = installed
  }

  private func removeDeviceListeners() {
    for deviceID in Array(deviceListenerAddresses.keys) {
      removeDeviceListeners(for: deviceID)
    }
  }

  private func removeDeviceListeners(for deviceID: AudioDeviceID) {
    guard let addresses = deviceListenerAddresses.removeValue(forKey: deviceID) else {
      return
    }
    for address in addresses {
      var address = address
      AudioObjectRemovePropertyListenerBlock(deviceID, &address, queue, listener)
    }
  }

  private static func observedAddresses(
    for device: MacGridAudioDevice
  ) -> [AudioObjectPropertyAddress] {
    var addresses = [
      AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyNominalSampleRate,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
      ),
      AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyAvailableNominalSampleRates,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
      ),
      AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyBufferFrameSize,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
      ),
      AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceIsAlive,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
      ),
      AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceHasChanged,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
      ),
    ]
    if device.hasInput {
      addresses.append(
        AudioObjectPropertyAddress(
          mSelector: kAudioDevicePropertyStreamFormat,
          mScope: kAudioDevicePropertyScopeInput,
          mElement: kAudioObjectPropertyElementMain
        )
      )
      addresses.append(
        AudioObjectPropertyAddress(
          mSelector: kAudioDevicePropertyDataSource,
          mScope: kAudioDevicePropertyScopeInput,
          mElement: kAudioObjectPropertyElementMain
        )
      )
    }
    if device.hasOutput {
      addresses.append(
        AudioObjectPropertyAddress(
          mSelector: kAudioDevicePropertyStreamFormat,
          mScope: kAudioDevicePropertyScopeOutput,
          mElement: kAudioObjectPropertyElementMain
        )
      )
      addresses.append(
        AudioObjectPropertyAddress(
          mSelector: kAudioDevicePropertyDataSource,
          mScope: kAudioDevicePropertyScopeOutput,
          mElement: kAudioObjectPropertyElementMain
        )
      )
    }
    return addresses
  }

  private static let observedSelectors: [AudioObjectPropertySelector] = [
    kAudioHardwarePropertyDevices,
    kAudioHardwarePropertyDefaultInputDevice,
    kAudioHardwarePropertyDefaultOutputDevice,
  ]
}

private enum MacGridCoreAudioProperty {
  static func value<T: BitwiseCopyable>(
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
    let expectedSize = UInt32(MemoryLayout<T>.stride)
    var size = expectedSize
    try checkMacGridAudioStatus(
      AudioObjectGetPropertyData(object, &address, 0, nil, &size, result),
      "read property \(selector)"
    )
    guard size == expectedSize else {
      throw MacGridCoreAudioError.unavailable(
        "Core Audio property \(selector) returned \(size) bytes; expected \(expectedSize)."
      )
    }
    // SAFETY: `T` is BitwiseCopyable, Core Audio returned success, and it
    // reported writing exactly one `T` stride into this aligned allocation.
    return result.move()
  }

  static func array<T: BitwiseCopyable>(
    _ type: T.Type,
    object: AudioObjectID,
    selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
  ) throws -> [T] {
    var address = AudioObjectPropertyAddress(
      mSelector: selector,
      mScope: scope,
      mElement: kAudioObjectPropertyElementMain
    )
    var size: UInt32 = 0
    try checkMacGridAudioStatus(
      AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size),
      "size property \(selector)"
    )
    guard size > 0 else { return [] }
    let stride = UInt32(MemoryLayout<T>.stride)
    guard size.isMultiple(of: stride) else {
      throw MacGridCoreAudioError.unavailable(
        "Core Audio property \(selector) returned a non-integral element byte count."
      )
    }
    let capacity = Int(size / stride)
    let storage = UnsafeMutablePointer<T>.allocate(capacity: capacity)
    defer { storage.deallocate() }
    try checkMacGridAudioStatus(
      AudioObjectGetPropertyData(object, &address, 0, nil, &size, storage),
      "read property array \(selector)"
    )
    guard size.isMultiple(of: stride), Int(size / stride) <= capacity else {
      throw MacGridCoreAudioError.unavailable(
        "Core Audio property \(selector) changed to an invalid size during readback."
      )
    }
    let count = Int(size / stride)
    // SAFETY: `T` is BitwiseCopyable, Core Audio returned success, and `count`
    // is derived from the post-read byte count within the allocated capacity.
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
    // Core Audio's CF-valued device properties are returned at +1. Both
    // kAudioObjectPropertyName and kAudioDevicePropertyDeviceUID explicitly
    // make the caller responsible for releasing the returned object.
    return value.takeRetainedValue() as String
  }

  static func streamFormat(
    object: AudioObjectID,
    scope: AudioObjectPropertyScope
  ) throws -> MacGridAudioStreamFormat {
    let description = try value(
      AudioStreamBasicDescription.self,
      object: object,
      selector: kAudioDevicePropertyStreamFormat,
      scope: scope
    )
    return MacGridAudioStreamFormat(description)
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
