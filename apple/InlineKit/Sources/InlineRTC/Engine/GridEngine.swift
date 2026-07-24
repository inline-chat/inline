import Foundation
import Logger

/// Process-wide ownership boundary for realtime media.
///
/// Product code submits complete desired state and observes immutable,
/// watch-style snapshots. Audio and RTC engines remain private implementation
/// details, so callers cannot create conflicting ownership or synchronization
/// paths by reaching into either engine directly.
public actor InlineRTCSession {
  private let audio: GridAudioEngine
  private let rtc: GridRTCEngine
  private nonisolated let commandMailbox: GridEngineCommandMailbox
  private let log = Log.scoped("InlineRTCSession")
  private var started = false
  private var subscribers: [UUID: AsyncStream<InlineRTCState>.Continuation] = [:]
  private var snapshotRevision: UInt64 = 0
  private var latestAudioSnapshot: InlineRTCAudioSnapshot?
  private var latestDeviceSnapshot: AudioInputDeviceSnapshot?
  private var latestOutputDeviceSnapshot: AudioOutputDeviceSnapshot?
  private var latestRTCSnapshot: InlineRTCConnectionSnapshot?
  private var eventTasks: [Task<Void, Never>] = []
  private var commandTask: Task<Void, Never>?
  private var permissionRequestTask: Task<Void, Never>?
  private var shutdownWaiters: [UUID: CheckedContinuation<GridMediaShutdownReceipt, Never>] = [:]

  public init(captureCooldown: Duration = .seconds(2)) {
    self.init(
      configuration: .voice,
      audioDriver: LiveKitGridAUHALAudioDriver(),
      permissionDriver: SystemGridMicrophonePermissionDriver(),
      rtcDriver: LiveKitGridRTCDriver(),
      captureCooldown: captureCooldown
    )
  }

  init(
    configuration: InlineRTCConfiguration = .voice,
    audioDriver: any GridAudioDriver,
    permissionDriver: any GridMicrophonePermissionDriver = SystemGridMicrophonePermissionDriver(),
    rtcDriver: any GridRTCDriver,
    captureCooldown: Duration = .seconds(2)
  ) {
    let audio = GridAudioEngine(
      driver: audioDriver,
      permissionDriver: permissionDriver,
      configuration: configuration,
      captureCooldown: captureCooldown
    )
    self.audio = audio
    rtc = GridRTCEngine(audio: audio, driver: rtcDriver, configuration: configuration)

    commandMailbox = GridEngineCommandMailbox()
  }

  deinit {
    commandTask?.cancel()
    permissionRequestTask?.cancel()
    eventTasks.forEach { $0.cancel() }
    let receipt = GridMediaShutdownReceipt(
      audio: GridAudioShutdownReceipt(
        recordingStopped: false,
        playoutStopped: false,
        mutationReleased: false,
        failures: ["InlineRTCSession deinitialized before shutdown completed."]
      ),
      rtc: GridRTCShutdownReceipt(
        locallyActiveRoomCount: 1,
        failures: []
      )
    )
    shutdownWaiters.values.forEach { $0.resume(returning: receipt) }
    subscribers.values.forEach { $0.finish() }
    commandMailbox.finish()
  }

  /// Updates the complete desired media state. Calls from one executor retain
  /// submission order and never expose the internal engine command protocol.
  public nonisolated func setDemand(_ demand: InlineRTCDemand) {
    enqueue(.setDemand(demand))
  }

  public nonisolated func refreshDevices() {
    enqueue(.refreshDevices)
  }

  public nonisolated func retryInput(_ selection: AudioInputSelection) {
    enqueue(.retryInput(selection))
  }

  public nonisolated func retryOutput(_ selection: AudioOutputSelection) {
    enqueue(.retryOutput(selection))
  }

  public nonisolated func requestMicrophonePermission() {
    enqueue(.requestMicrophonePermission)
  }

  public nonisolated func retryAudio() {
    enqueue(.retryAudio)
  }

  public func screenCaptureSources() async throws -> [InlineRTCScreenCaptureSource] {
    try await rtc.screenCaptureSources()
  }

  public nonisolated func networkBecameAvailable() {
    enqueue(.networkBecameAvailable)
  }

  public nonisolated func applicationDidWake() {
    enqueue(.applicationDidWake)
  }

  /// Best-effort terminal request for owner deinitialization, where awaiting
  /// `shutdown()` is impossible.
  public nonisolated func requestShutdown() {
    enqueue(.shutdown(requestID: UUID()))
  }

  /// Creates an independent watch-style subscription to the process-wide
  /// media runtime. Every call owns a distinct AsyncStream; Swift consumers
  /// never compete for elements from a shared iterator.
  public func subscribe() async -> AsyncStream<InlineRTCState> {
    let subscriptionID = UUID()
    let stream = AsyncStream.makeStream(
      of: InlineRTCState.self,
      // Snapshots are complete projections, so coalescing is safe and bounds
      // memory if a UI consumer is temporarily suspended.
      bufferingPolicy: .bufferingNewest(1)
    )
    stream.continuation.onTermination = { [weak self] _ in
      Task { await self?.removeSubscriber(subscriptionID) }
    }
    subscribers[subscriptionID] = stream.continuation

    if latestAudioSnapshot == nil {
      latestAudioSnapshot = await audio.currentSnapshot()
    }
    if latestRTCSnapshot == nil {
      latestRTCSnapshot = await rtc.currentSnapshot()
    }
    if let snapshot = currentSnapshot() {
      stream.continuation.yield(snapshot)
    }
    return stream.stream
  }

  public func start() async {
    guard !started else { return }
    started = true
    log.debug("GRID_ENGINE phase=engine_start_started")

    eventTasks = [
      forward(audio.snapshots, transform: GridModuleEvent.audio),
      forward(audio.deviceSnapshots, transform: GridModuleEvent.devices),
      forward(audio.outputDeviceSnapshots, transform: GridModuleEvent.outputDevices),
      forward(rtc.snapshots, transform: GridModuleEvent.rtc),
    ]
    commandTask = Task { [weak self, commandMailbox] in
      for await _ in commandMailbox.signals {
        guard !Task.isCancelled else { return }
        while let command = commandMailbox.dequeue() {
          guard !Task.isCancelled else { return }
          await self?.handle(command)
        }
      }
    }
    await audio.start()
    log.debug("GRID_ENGINE phase=engine_start_finished")
  }

  /// Terminal lifecycle operation used by logout. Pending product intent is
  /// followed by an explicit empty demand before media is disconnected. The
  /// mailbox remains alive so the same authenticated-process runtime can be
  /// reused if application dependencies survive a logout/login transition.
  public func shutdown() async -> GridMediaShutdownReceipt {
    await start()
    let requestID = UUID()
    return await withCheckedContinuation { continuation in
      shutdownWaiters[requestID] = continuation
      enqueue(.shutdown(requestID: requestID))
    }
  }

  private func handle(_ command: GridEngineCommand) async {
    switch command {
    case let .setDemand(demand):
      await rtc.setDemand(demand)
    case .refreshDevices:
      _ = await audio.deviceSnapshot()
      _ = await audio.outputDeviceSnapshot()
    case let .retryInput(selection):
      await audio.retryInput(selection)
    case let .retryOutput(selection):
      await audio.retryOutput(selection)
    case .requestMicrophonePermission:
      startMicrophonePermissionRequest()
    case .retryAudio:
      await audio.retry()
      await rtc.audioAvailabilityChanged()
    case .networkBecameAvailable:
      await audio.checkRuntimeHealthAfterInterruption()
      await rtc.networkBecameAvailable()
    case .applicationDidWake:
      await audio.checkRuntimeHealthAfterInterruption()
      await rtc.applicationDidWake()
    case let .shutdown(requestID):
      let rtcReceipt = await rtc.shutdown()
      let audioReceipt = await audio.shutdown()
      let receipt = GridMediaShutdownReceipt(audio: audioReceipt, rtc: rtcReceipt)
      if receipt.isLocallyQuiescent {
        log.info("GRID_ENGINE phase=engine_shutdown_finished locally_quiescent=true")
      } else {
        log.error(
          "GRID_ENGINE phase=engine_shutdown_incomplete locally_quiescent=false active_rooms=\(receipt.locallyActiveRoomCount) rtc_media_mutations=\(receipt.rtcLocalMediaMutationCount) microphone_publications=\(receipt.microphonePublicationCount) screen_publications=\(receipt.screenSharePublicationCount) audio_mutation_released=\(receipt.audioMutationReleased) failures=\(receipt.failures.joined(separator: ","))"
        )
      }
      shutdownWaiters.removeValue(forKey: requestID)?.resume(returning: receipt)
    }
  }

  private nonisolated func enqueue(_ command: GridEngineCommand) {
    commandMailbox.enqueue(command)
  }

  /// Permission UI can remain open for an arbitrary amount of time. It must
  /// never occupy the command mailbox: room demand can connect listen-only,
  /// and leave/switch/shutdown commands must remain immediately processable.
  private func startMicrophonePermissionRequest() {
    guard permissionRequestTask == nil else { return }
    permissionRequestTask = Task { [weak self, audio, rtc] in
      await audio.requestMicrophonePermission()
      guard !Task.isCancelled else { return }
      await rtc.audioAvailabilityChanged()
      await self?.permissionRequestFinished()
    }
  }

  private func permissionRequestFinished() {
    permissionRequestTask = nil
  }

  private func forward<Value: Sendable>(
    _ stream: AsyncStream<Value>,
    transform: @escaping @Sendable (Value) -> GridModuleEvent
  ) -> Task<Void, Never> {
    return Task {
      for await value in stream {
        guard !Task.isCancelled else { return }
        await self.receive(transform(value))
      }
    }
  }

  private func receive(_ event: GridModuleEvent) async {
    switch event {
    case let .audio(snapshot):
      let previous = latestAudioSnapshot
      latestAudioSnapshot = snapshot
      if previous?.isPrepared != snapshot.isPrepared
        || previous?.microphonePermission != snapshot.microphonePermission {
        await rtc.audioAvailabilityChanged()
      }
    case let .devices(snapshot):
      latestDeviceSnapshot = snapshot
    case let .outputDevices(snapshot):
      latestOutputDeviceSnapshot = snapshot
    case let .rtc(snapshot):
      latestRTCSnapshot = snapshot
    }
    snapshotRevision &+= 1
    guard let snapshot = currentSnapshot() else { return }
    for continuation in subscribers.values {
      continuation.yield(snapshot)
    }
  }

  private func currentSnapshot() -> InlineRTCState? {
    guard let audio = latestAudioSnapshot, let rtc = latestRTCSnapshot else { return nil }
    return InlineRTCState(
      revision: snapshotRevision,
      audio: audio,
      devices: latestDeviceSnapshot,
      outputDevices: latestOutputDeviceSnapshot,
      rtc: rtc
    )
  }

  private func removeSubscriber(_ subscriptionID: UUID) {
    subscribers.removeValue(forKey: subscriptionID)
  }
}

private enum GridModuleEvent: Sendable {
  case audio(InlineRTCAudioSnapshot)
  case devices(AudioInputDeviceSnapshot)
  case outputDevices(AudioOutputDeviceSnapshot)
  case rtc(InlineRTCConnectionSnapshot)
}
