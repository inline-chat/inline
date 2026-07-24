import Foundation
import LiveKit
import Logger

actor LiveKitGridRTCDriver: GridRTCDriver {
  nonisolated let lifecycleEvents: AsyncStream<GridRTCLifecycleEventEnvelope>
  nonisolated let participantSnapshots: AsyncStream<GridRTCParticipantSnapshotEnvelope>

  private nonisolated let lifecycleContinuation: AsyncStream<GridRTCLifecycleEventEnvelope>.Continuation
  private nonisolated let participantContinuation: AsyncStream<GridRTCParticipantSnapshotEnvelope>.Continuation
  private var rooms: [GridRTCRoomHandle: RoomContext] = [:]
  private let log = Log.scoped("LiveKitGridRTCDriver")

  init() {
    let lifecycleStream = AsyncStream.makeStream(
      of: GridRTCLifecycleEventEnvelope.self,
      // Speaking levels use their own replaceable stream. Lifecycle edges are
      // sparse, but must still have a hard lifetime bound under suspension.
      bufferingPolicy: .bufferingNewest(128)
    )
    lifecycleEvents = lifecycleStream.stream
    lifecycleContinuation = lifecycleStream.continuation
    let participantStream = AsyncStream.makeStream(
      of: GridRTCParticipantSnapshotEnvelope.self,
      // Speaking levels are complete replaceable snapshots. Bound them so a
      // suspended consumer cannot grow memory during a long conversation.
      bufferingPolicy: .bufferingNewest(2)
    )
    participantSnapshots = participantStream.stream
    participantContinuation = participantStream.continuation
  }

  deinit {
    lifecycleContinuation.finish()
    participantContinuation.finish()
  }

  func makeRoom(configuration: InlineRTCConfiguration) async throws -> GridRTCRoomHandle {
    let handle = GridRTCRoomHandle()
    let delegate = LiveKitGridRoomDelegate(
      handle: handle,
      lifecycleContinuation: lifecycleContinuation,
      participantContinuation: participantContinuation,
      remoteFlowCheckInterval: configuration.connection.remoteAudioFlowCheckInterval,
      remoteFlowMissThreshold: configuration.connection.remoteAudioFlowMissThreshold
    )
    let room = Room(
      delegate: delegate,
      connectOptions: configuration.makeConnectOptions(microphoneEnabled: false),
      roomOptions: configuration.makeRoomOptions()
    )
    rooms[handle] = RoomContext(room: room, delegate: delegate, configuration: configuration)
    log.debug("GRID_ENGINE phase=livekit_room_created handle=\(handle.id)")
    return handle
  }

  func connect(_ room: GridRTCRoomHandle, credentials: InlineRTCCredentials) async throws {
    let context = try context(for: room)
    if context.configuration.connection.prepareCloudConnection {
      let preparationStartedAt = Date()
      log.debug(
        "GRID_ENGINE phase=livekit_prepare_started handle=\(room.id) session=\(credentials.target.rawValue)"
      )
      do {
        try await context.room.prepareConnection(
          url: credentials.serverURL.absoluteString,
          token: credentials.token
        )
        log.debug(
          "GRID_ENGINE phase=livekit_prepare_finished handle=\(room.id) elapsed_ms=\(Self.elapsedMilliseconds(since: preparationStartedAt))"
        )
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        // Preparation is an optimization. LiveKit's normal connect path still
        // performs region failover, so discovery failure must not prevent a
        // connection that could otherwise succeed.
        log.warning(
          "GRID_ENGINE phase=livekit_prepare_failed handle=\(room.id) elapsed_ms=\(Self.elapsedMilliseconds(since: preparationStartedAt)) fallback=normal_connect"
        )
      }
    }

    try Task.checkCancellation()
    let startedAt = Date()
    log.debug(
      "GRID_ENGINE phase=livekit_connect_started handle=\(room.id) session=\(credentials.target.rawValue)"
    )
    try await context.room.connect(
      url: credentials.serverURL.absoluteString,
      token: credentials.token
    )
    log.debug(
      "GRID_ENGINE phase=livekit_connect_finished handle=\(room.id) elapsed_ms=\(Self.elapsedMilliseconds(since: startedAt))"
    )
    if let span = context.room.connectSpan {
      log.debug("GRID_ENGINE phase=livekit_connect_span handle=\(room.id) \(span)")
    }
  }

  func publishPreparedMicrophone(
    _ room: GridRTCRoomHandle,
    initiallyMuted: Bool
  ) async throws {
    let context = try context(for: room)
    try beginLocalMediaMutation(in: context)
    defer { endLocalMediaMutation(in: room, context: context) }
    let track: LocalAudioTrack
    if let cachedTrack = context.microphoneTrack,
       isPublished(cachedTrack, in: context) {
      await cachedTrack.set(reportStatistics: true)
      try applyAndVerifyAudioProcessing(to: cachedTrack, context: context)
      if initiallyMuted {
        try await cachedTrack.mute()
        stopLocalFlowMonitoring(in: room, context: context)
      } else {
        let baseline = GridLocalAudioTransportSnapshot(
          statistics: cachedTrack.statistics
        )
        try await cachedTrack.unmute()
        try applyAndVerifyAudioProcessing(to: cachedTrack, context: context)
        scheduleLocalFlowCheck(
          in: room,
          track: cachedTrack,
          baseline: baseline,
          reason: "republish_unmute",
          delay: context.configuration.connection.localAudioFlowStartupTimeout
        )
      }
      return
    } else if let cachedTrack = context.microphoneTrack {
      track = cachedTrack
      log.warning(
        "GRID_ENGINE phase=livekit_microphone_publication_stale handle=\(room.id) action=republish_cached_track"
      )
    } else {
      track = LocalAudioTrack.createTrack(
        options: context.configuration.makeRoomOptions().defaultAudioCaptureOptions,
        reportStatistics: true
      )
      context.microphoneTrack = track
      log.debug(
        "GRID_ENGINE phase=livekit_microphone_created handle=\(room.id) initially_muted=\(initiallyMuted)"
      )
    }
    await track.set(reportStatistics: true)

    // Track-scoped APM intent must be stored before publication, then applied
    // and verified again once a real sender exists. The AudioEngine ADM
    // can prewarm capture without a sender, but it cannot apply media-engine
    // AEC/NS options by itself.
    try storeAudioProcessingIntent(on: track, context: context)

    // Establish the muted state before capture starts or signaling can publish
    // the track. No enabled pre-publication frame can reach another participant.
    if initiallyMuted {
      try await track.mute()
    }
    let startedAt = Date()
    log.debug(
      "GRID_ENGINE phase=livekit_microphone_publish_started handle=\(room.id) muted=\(track.isMuted)"
    )
    let transportBaseline = GridLocalAudioTransportSnapshot(
      statistics: track.statistics
    )
    _ = try await context.room.localParticipant.publish(
      audioTrack: track,
      options: context.configuration.makeRoomOptions().defaultAudioPublishOptions
    )
    try applyAndVerifyAudioProcessing(to: track, context: context)
    log.debug(
      "GRID_ENGINE phase=livekit_microphone_publish_finished handle=\(room.id) elapsed_ms=\(Self.elapsedMilliseconds(since: startedAt)) muted=\(track.isMuted)"
    )
    if !track.isMuted {
      scheduleLocalFlowCheck(
        in: room,
        track: track,
        baseline: transportBaseline,
        reason: "publish",
        delay: context.configuration.connection.localAudioFlowStartupTimeout
      )
    }
  }

  func setMicrophoneMuted(_ muted: Bool, in room: GridRTCRoomHandle) async throws {
    let context = try context(for: room)
    try beginLocalMediaMutation(in: context)
    defer { endLocalMediaMutation(in: room, context: context) }
    guard let track = context.microphoneTrack else {
      throw LiveKitGridRTCDriverError.microphoneNotPublished
    }
    let baseline = GridLocalAudioTransportSnapshot(statistics: track.statistics)
    if muted {
      try await track.mute()
      stopLocalFlowMonitoring(in: room, context: context)
    } else {
      try await track.unmute()
      try applyAndVerifyAudioProcessing(to: track, context: context)
    }
    log.debug(
      "GRID_ENGINE phase=livekit_microphone_mute_applied handle=\(room.id) muted=\(muted)"
    )
    if !muted {
      scheduleLocalFlowCheck(
        in: room,
        track: track,
        baseline: baseline,
        reason: "unmute",
        delay: context.configuration.connection.localAudioFlowStartupTimeout
      )
    }
  }

  func screenCaptureSources() async throws -> [InlineRTCScreenCaptureSource] {
    #if os(macOS)
    guard #available(macOS 12.3, *) else {
      throw LiveKitGridRTCDriverError.screenSharingUnavailable
    }
    let displays = try await MacOSScreenCapturer.displaySources()
    return displays.enumerated().map { index, display in
      InlineRTCScreenCaptureSource(display: display, index: index)
    }
    #else
    throw LiveKitGridRTCDriverError.screenSharingUnavailable
    #endif
  }

  func setScreenShare(
    _ source: InlineRTCScreenCaptureSource?,
    in room: GridRTCRoomHandle
  ) async throws {
    #if os(macOS)
    guard #available(macOS 12.3, *) else {
      throw LiveKitGridRTCDriverError.screenSharingUnavailable
    }
    let context = try context(for: room)
    try beginLocalMediaMutation(in: context)
    defer { endLocalMediaMutation(in: room, context: context) }
    if context.screenCaptureSourceID == source?.id,
       context.room.localParticipant.firstScreenSharePublication != nil {
      return
    }

    guard let source else {
      if let publication = context.room.localParticipant
        .firstScreenSharePublication as? LocalTrackPublication {
        try await unpublishScreenShare(publication, context: context)
      }
      context.screenShareTrack = nil
      context.screenCaptureSourceID = nil
      context.delegate.setLocalScreenCaptureSourceID(nil)
      log.debug("GRID_ENGINE phase=livekit_screen_share_stopped handle=\(room.id)")
      return
    }
    guard let liveKitSource = source.liveKitSource else {
      throw LiveKitGridRTCDriverError.invalidScreenCaptureSource
    }

    if let publication = context.room.localParticipant
      .firstScreenSharePublication as? LocalTrackPublication {
      guard let track = publication.track as? LocalVideoTrack,
            let capturer = track.capturer as? MacOSScreenCapturer
      else {
        throw LiveKitGridRTCDriverError.screenSharePublicationTransitioning
      }
      try await capturer.updateCaptureSource(liveKitSource)
      context.screenShareTrack = track
      context.screenCaptureSourceID = source.id
      context.delegate.setLocalScreenCaptureSourceID(source.id)
      context.delegate.refreshScreenShares(in: context.room)
      log.debug(
        "GRID_ENGINE phase=livekit_screen_share_source_updated handle=\(room.id) source=\(source.id) publication=\(publication.sid)"
      )
      return
    }
    guard context.screenShareTrack == nil else {
      // A full reconnect retains the track while LiveKit serially replaces its
      // publication. The engine waits for that replacement; never publish a
      // second track if a demand update happens during the turnover gap.
      throw LiveKitGridRTCDriverError.screenSharePublicationTransitioning
    }

    let roomOptions = context.configuration.makeRoomOptions()
    let track = LocalVideoTrack.createMacOSScreenShareTrack(
      source: liveKitSource,
      options: roomOptions.defaultScreenShareCaptureOptions
    )
    context.screenCaptureSourceID = source.id
    context.delegate.setLocalScreenCaptureSourceID(source.id)
    do {
      _ = try await context.room.localParticipant.publish(
        videoTrack: track,
        options: roomOptions.defaultVideoPublishOptions
      )
      context.screenShareTrack = track
    } catch {
      context.screenCaptureSourceID = nil
      context.delegate.setLocalScreenCaptureSourceID(nil)
      throw error
    }
    log.debug(
      "GRID_ENGINE phase=livekit_screen_share_published handle=\(room.id) source=\(source.id)"
    )
    #else
    throw LiveKitGridRTCDriverError.screenSharingUnavailable
    #endif
  }

  func setOutputVolume(_ volume: Float, in room: GridRTCRoomHandle) async {
    guard let context = rooms[room] else { return }
    let clamped = Double(min(max(volume, 0), 1))
    context.delegate.setOutputVolume(clamped)
    for participant in context.room.remoteParticipants.values {
      for publication in participant.audioTracks {
        (publication.track as? RemoteAudioTrack)?.volume = clamped
      }
    }
  }

  func silence(_ room: GridRTCRoomHandle) async {
    guard let context = rooms[room] else { return }
    stopLocalFlowMonitoring(in: room, context: context)
    try? await context.microphoneTrack?.mute()
    if let publication = context.room.localParticipant
      .firstScreenSharePublication as? LocalTrackPublication {
      try? await unpublishScreenShare(publication, context: context)
    }
    context.screenShareTrack = nil
    context.screenCaptureSourceID = nil
    context.delegate.setLocalScreenCaptureSourceID(nil)
    for participant in context.room.remoteParticipants.values {
      for publication in participant.audioTracks {
        (publication.track as? RemoteAudioTrack)?.volume = 0
      }
    }
    log.debug("GRID_ENGINE phase=livekit_room_silenced handle=\(room.id)")
  }

  func disconnect(_ room: GridRTCRoomHandle) async {
    guard let context = rooms.removeValue(forKey: room) else { return }
    let startedAt = Date()
    context.localFlowCheckTask?.cancel()
    context.localFlowCheckTask = nil
    try? await context.microphoneTrack?.mute()
    await context.room.disconnect()
    log.debug(
      "GRID_ENGINE phase=livekit_disconnect_finished handle=\(room.id) elapsed_ms=\(Self.elapsedMilliseconds(since: startedAt))"
    )
  }

  func quiesceLocally(_ room: GridRTCRoomHandle) async -> GridLocalRoomQuiescenceReceipt {
    guard let context = rooms[room] else {
      return GridLocalRoomQuiescenceReceipt(
        room: room,
        localResourcesReleased: true,
        failures: []
      )
    }
    let startedAt = Date()
    context.isLocallyRetired = true
    context.localFlowCheckTask?.cancel()
    context.localFlowCheckTask = nil
    await context.room.disconnectLocally()
    let microphonePublicationCount = context.room.localParticipant.localAudioTracks
      .filter { $0.source == .microphone }
      .count
    let screenSharePublicationCount = context.room.localParticipant.localVideoTracks
      .filter { $0.source == .screenShareVideo }
      .count
      + context.room.localParticipant.localAudioTracks
      .filter { $0.source == .screenShareAudio }
      .count
    let microphoneCaptureStopped = context.microphoneTrack?.trackState != .started
    let screenCaptureStopped = context.screenShareTrack?.trackState != .started
    let localMediaMutationCount = context.localMediaMutationCount
    let released = context.room.connectionState == .disconnected
      && localMediaMutationCount == 0
      && microphonePublicationCount == 0
      && screenSharePublicationCount == 0
      && microphoneCaptureStopped
      && screenCaptureStopped
    if released {
      rooms[room] = nil
    }
    var failures: [String] = []
    if context.room.connectionState != .disconnected {
      failures.append("LiveKit room remained locally active after local disconnect.")
    }
    if localMediaMutationCount > 0 {
      failures.append(
        "LiveKit retained \(localMediaMutationCount) local media mutation(s) after local disconnect."
      )
    }
    if microphonePublicationCount > 0 {
      failures.append(
        "LiveKit retained \(microphonePublicationCount) microphone publication(s) after local disconnect."
      )
    }
    if screenSharePublicationCount > 0 {
      failures.append(
        "LiveKit retained \(screenSharePublicationCount) screen-share publication(s) after local disconnect."
      )
    }
    if !microphoneCaptureStopped {
      failures.append("LiveKit microphone capture remained started after local disconnect.")
    }
    if !screenCaptureStopped {
      failures.append("LiveKit screen capture remained started after local disconnect.")
    }
    log.debug(
      "GRID_ENGINE phase=livekit_local_quiescence_finished handle=\(room.id) released=\(released) local_media_mutations=\(localMediaMutationCount) microphone_publications=\(microphonePublicationCount) screen_publications=\(screenSharePublicationCount) microphone_capture_stopped=\(microphoneCaptureStopped) screen_capture_stopped=\(screenCaptureStopped) elapsed_ms=\(Self.elapsedMilliseconds(since: startedAt))"
    )
    return GridLocalRoomQuiescenceReceipt(
      room: room,
      localResourcesReleased: released,
      localMediaMutationCount: localMediaMutationCount,
      microphonePublicationCount: microphonePublicationCount,
      screenSharePublicationCount: screenSharePublicationCount,
      failures: failures
    )
  }

  private func context(for room: GridRTCRoomHandle) throws -> RoomContext {
    guard let context = rooms[room] else {
      throw LiveKitGridRTCDriverError.roomNotFound
    }
    return context
  }

  private func beginLocalMediaMutation(in context: RoomContext) throws {
    guard !context.isLocallyRetired else {
      throw LiveKitGridRTCDriverError.roomLocallyRetired
    }
    context.localMediaMutationCount += 1
  }

  private func endLocalMediaMutation(
    in room: GridRTCRoomHandle,
    context: RoomContext
  ) {
    context.localMediaMutationCount = max(context.localMediaMutationCount - 1, 0)
    guard context.isLocallyRetired, context.localMediaMutationCount == 0 else { return }
    lifecycleContinuation.yield(
      GridRTCLifecycleEventEnvelope(
        room: room,
        event: .retiredLocalMediaMutationReleased
      )
    )
  }

  private func unpublishScreenShare(
    _ publication: LocalTrackPublication,
    context: RoomContext
  ) async throws {
    try await context.room.localParticipant.unpublish(publication: publication)
  }

  private func isPublished(_ track: LocalAudioTrack, in context: RoomContext) -> Bool {
    context.room.localParticipant.localAudioTracks.contains { publication in
      publication.track === track
    }
  }

  private func storeAudioProcessingIntent(
    on track: LocalAudioTrack,
    context: RoomContext
  ) throws {
    _ = try track.setAudioProcessingOptions(
      context.configuration.makeAudioProcessingOptions()
    )
  }

  private func applyAndVerifyAudioProcessing(
    to track: LocalAudioTrack,
    context: RoomContext
  ) throws {
    let result = try track.setAudioProcessingOptions(
      context.configuration.makeAudioProcessingOptions()
    )
    #if os(macOS)
    // A muted or not-yet-negotiated track has no active audio sender. WebRTC
    // accepts and stores the policy on the source, then reapplies it when the
    // sender becomes active. Treating that documented success as an immediate
    // effective-state failure prevents the later unmute that activates both
    // the sender and the native audio-device recording gate.
    if case .stored = result {
      log.info(
        "GRID_ENGINE phase=livekit_audio_processing_deferred reason=sender_not_active"
      )
      return
    }
    let processing = MacGridLiveKitAudioProcessingPolicy.snapshot()
    guard processing.isGridPolicyEffective else {
      throw LiveKitGridRTCDriverError.audioProcessingPolicyNotEffective(
        processing.logDescription
      )
    }
    log.info(
      "GRID_ENGINE phase=livekit_audio_processing_verified \(processing.logDescription)"
    )
    #endif
  }

  private func scheduleLocalFlowCheck(
    in room: GridRTCRoomHandle,
    track: LocalAudioTrack,
    baseline: GridLocalAudioTransportSnapshot,
    reason: String,
    delay: TimeInterval,
    resetProof: Bool = true
  ) {
    guard let context = rooms[room], context.microphoneTrack?.isMuted == false else { return }
    context.localFlowCheckTask?.cancel()
    if resetProof {
      context.localFlowGeneration &+= 1
      context.localFlowProof.reset()
    }
    let generation = context.localFlowGeneration
    context.localFlowCheckTask = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(Int(max(delay, 0) * 1_000)))
      guard !Task.isCancelled else { return }
      await self?.reportLocalFlow(
        in: room,
        track: track,
        baseline: baseline,
        reason: reason,
        generation: generation
      )
    }
  }

  private func reportLocalFlow(
    in room: GridRTCRoomHandle,
    track: LocalAudioTrack,
    baseline: GridLocalAudioTransportSnapshot,
    reason: String,
    generation: UInt64
  ) {
    guard let context = rooms[room],
          context.microphoneTrack === track,
          !track.isMuted,
          context.localFlowGeneration == generation
    else { return }
    context.localFlowCheckTask = nil
    let snapshot = GridLocalAudioTransportSnapshot(statistics: track.statistics)
    let observation = context.localFlowProof.observe(
      hasProgress: snapshot.hasProgress(since: baseline)
    )
    switch observation {
    case let .suspect(consecutiveMisses):
      log.warning(
        "GRID_ENGINE phase=livekit_local_audio_flow_suspect handle=\(room.id) reason=\(reason) proof=outbound_rtp consecutive_misses=\(consecutiveMisses) packets=\(snapshot.packetCount) bytes=\(snapshot.byteCount) baseline_packets=\(baseline.packetCount) baseline_bytes=\(baseline.byteCount) action=confirm"
      )
    case let .missing(consecutiveMisses):
      log.warning(
        "GRID_ENGINE phase=livekit_local_audio_flow_missing handle=\(room.id) reason=\(reason) proof=outbound_rtp consecutive_misses=\(consecutiveMisses) streams=\(snapshot.streams.count) packets=\(snapshot.packetCount) bytes=\(snapshot.byteCount) baseline_packets=\(baseline.packetCount) baseline_bytes=\(baseline.byteCount)"
      )
      emitLocalFlow(.missing, in: room)
    case .flowing:
      log.debug(
        "GRID_ENGINE phase=livekit_local_audio_flow_confirmed handle=\(room.id) reason=\(reason) proof=outbound_rtp streams=\(snapshot.streams.count) packets=\(snapshot.packetCount) bytes=\(snapshot.byteCount) baseline_packets=\(baseline.packetCount) baseline_bytes=\(baseline.byteCount)"
      )
      emitLocalFlow(.flowing, in: room)
    }
    scheduleLocalFlowCheck(
      in: room,
      track: track,
      baseline: snapshot,
      reason: observation == .flowing ? "lifetime" : "confirmation",
      delay: observation == .flowing
        ? context.configuration.connection.localAudioFlowCheckInterval
        : context.configuration.connection.localAudioFlowStartupTimeout,
      resetProof: false
    )
  }

  private func stopLocalFlowMonitoring(
    in room: GridRTCRoomHandle,
    context: RoomContext
  ) {
    context.localFlowCheckTask?.cancel()
    context.localFlowCheckTask = nil
    context.localFlowGeneration &+= 1
    context.localFlowProof.reset()
    emitLocalFlow(.unknown, in: room)
  }

  private func emitLocalFlow(
    _ state: InlineRTCAudioFlowState,
    in room: GridRTCRoomHandle
  ) {
    lifecycleContinuation.yield(
      GridRTCLifecycleEventEnvelope(room: room, event: .localAudioFlow(state))
    )
  }

  private static func elapsedMilliseconds(since date: Date) -> Int {
    Int(Date().timeIntervalSince(date) * 1_000)
  }
}

private final class RoomContext: @unchecked Sendable {
  let room: Room
  let delegate: LiveKitGridRoomDelegate
  let configuration: InlineRTCConfiguration
  var microphoneTrack: LocalAudioTrack?
  var screenShareTrack: LocalVideoTrack?
  var screenCaptureSourceID: String?
  var localFlowCheckTask: Task<Void, Never>?
  var localFlowGeneration: UInt64 = 0
  var localFlowProof: GridLocalAudioTransportProof
  var isLocallyRetired = false
  var localMediaMutationCount = 0

  init(
    room: Room,
    delegate: LiveKitGridRoomDelegate,
    configuration: InlineRTCConfiguration
  ) {
    self.room = room
    self.delegate = delegate
    self.configuration = configuration
    localFlowProof = GridLocalAudioTransportProof(
      missThreshold: configuration.connection.localAudioFlowMissThreshold
    )
  }
}

private final class LiveKitGridRoomDelegate: NSObject, RoomDelegate, @unchecked Sendable {
  private let handle: GridRTCRoomHandle
  private let lifecycleContinuation: AsyncStream<GridRTCLifecycleEventEnvelope>.Continuation
  private let participantContinuation: AsyncStream<GridRTCParticipantSnapshotEnvelope>.Continuation
  private let remoteFlowCheckInterval: TimeInterval
  private let remoteFlowMissThreshold: Int
  private let log = Log.scoped("LiveKitGridRoomDelegate")
  private let localScreenShareLock = NSLock()
  private var localScreenCaptureSourceID: String?
  private var screenShareSnapshotRevision: UInt64 = 0
  private let remoteFlowLock = NSLock()
  private var remoteFlowProbes: [String: RemoteFlowContext] = [:]
  private var outputVolume: Double = 1

  init(
    handle: GridRTCRoomHandle,
    lifecycleContinuation: AsyncStream<GridRTCLifecycleEventEnvelope>.Continuation,
    participantContinuation: AsyncStream<GridRTCParticipantSnapshotEnvelope>.Continuation,
    remoteFlowCheckInterval: TimeInterval,
    remoteFlowMissThreshold: Int
  ) {
    self.handle = handle
    self.lifecycleContinuation = lifecycleContinuation
    self.participantContinuation = participantContinuation
    self.remoteFlowCheckInterval = remoteFlowCheckInterval
    self.remoteFlowMissThreshold = max(remoteFlowMissThreshold, 1)
  }

  deinit {
    let contexts = remoteFlowLock.withLock {
      let contexts = Array(remoteFlowProbes.values)
      remoteFlowProbes.removeAll()
      return contexts
    }
    for context in contexts {
      context.checkTask?.cancel()
      context.track?.remove(audioRenderer: context.probe)
    }
  }

  func setLocalScreenCaptureSourceID(_ sourceID: String?) {
    localScreenShareLock.withLock {
      localScreenCaptureSourceID = sourceID
    }
  }

  func refreshScreenShares(in room: Room) {
    emitScreenShares(in: room)
  }

  func room(_ room: Room, didUpdateSpeakingParticipants _: [Participant]) {
    emitParticipants(in: room)
    updateRemoteFlowMonitoring()
  }

  func room(
    _: Room,
    participant: Participant,
    didUpdateConnectionQuality quality: ConnectionQuality
  ) {
    log.info(
      "GRID_ENGINE phase=livekit_connection_quality handle=\(handle.id) participant=\(participant.identity?.stringValue ?? "unknown") local=\(participant is LocalParticipant) quality=\(quality)"
    )
  }

  func room(_ room: Room, participantDidConnect _: RemoteParticipant) {
    emitParticipants(in: room)
    emitScreenShares(in: room)
  }

  func room(_ room: Room, participantDidDisconnect _: RemoteParticipant) {
    emitParticipants(in: room)
    emitScreenShares(in: room)
  }

  func room(
    _ room: Room,
    participant: RemoteParticipant,
    didPublishTrack publication: RemoteTrackPublication
  ) {
    log.debug(
      "GRID_ENGINE phase=livekit_remote_track_announced handle=\(handle.id) participant=\(identity(of: participant)) track=\(publication.sid) kind=\(publication.kind) source=\(publication.source)"
    )
    if publication.source == .screenShareVideo {
      emitScreenShares(in: room)
    }
  }

  func room(
    _ room: Room,
    participant _: RemoteParticipant,
    didUnpublishTrack publication: RemoteTrackPublication
  ) {
    if publication.source == .screenShareVideo {
      emitScreenShares(in: room)
    }
  }

  func room(
    _ room: Room,
    participant: RemoteParticipant,
    didSubscribeTrack publication: RemoteTrackPublication
  ) {
    if let track = publication.track as? RemoteAudioTrack {
      track.volume = remoteFlowLock.withLock { outputVolume }
      let probe = GridAudioFlowProbe()
      track.add(audioRenderer: probe)
      let key = String(describing: publication.sid)
      let context = RemoteFlowContext(
        track: track,
        publication: publication,
        participant: participant,
        identity: identity(of: participant),
        probe: probe
      )
      let oldContext = remoteFlowLock.withLock {
        remoteFlowProbes.updateValue(context, forKey: key)
      }
      if let oldContext {
        oldContext.checkTask?.cancel()
        oldContext.track?.remove(audioRenderer: oldContext.probe)
      }
      if !publication.isMuted, participant.isSpeaking {
        scheduleRemoteFlowCheck(key: key, context: context, reason: "subscribe")
      }
    }
    log.debug(
      "GRID_ENGINE phase=livekit_remote_track_subscribed handle=\(handle.id) participant=\(identity(of: participant)) track=\(publication.sid) kind=\(publication.kind) source=\(publication.source)"
    )
    if publication.source == .screenShareVideo {
      emitScreenShares(in: room)
    }
  }

  func room(
    _ room: Room,
    participant: Participant,
    trackPublication: TrackPublication,
    didUpdateIsMuted isMuted: Bool
  ) {
    guard let remoteParticipant = participant as? RemoteParticipant,
          let publication = trackPublication as? RemoteTrackPublication
    else { return }
    if publication.source == .screenShareVideo {
      emitScreenShares(in: room)
      return
    }
    let key = String(describing: publication.sid)
    guard let context = remoteFlowLock.withLock({ remoteFlowProbes[key] }) else { return }
    if isMuted {
      stopRemoteFlowMonitoring(key: key, context: context)
      return
    }
    let participantIdentity = remoteParticipant.identity?.stringValue ?? "unknown"
    log.debug(
      "GRID_ENGINE phase=livekit_remote_track_unmuted handle=\(handle.id) participant=\(participantIdentity) track=\(trackPublication.sid)"
    )
    if remoteParticipant.isSpeaking {
      scheduleRemoteFlowCheck(key: key, context: context, reason: "unmute")
    }
  }

  func room(
    _ room: Room,
    participant: RemoteParticipant,
    didUnsubscribeTrack publication: RemoteTrackPublication
  ) {
    let key = String(describing: publication.sid)
    if let context = remoteFlowLock.withLock({ remoteFlowProbes.removeValue(forKey: key) }) {
      context.checkTask?.cancel()
      context.track?.remove(audioRenderer: context.probe)
      if context.state != .unknown {
        emitLifecycle(.remoteAudioFlow(identity: context.identity, state: .unknown))
      }
    }
    log.debug(
      "GRID_ENGINE phase=livekit_remote_track_unsubscribed handle=\(handle.id) participant=\(identity(of: participant)) track=\(publication.sid)"
    )
    if publication.source == .screenShareVideo {
      emitScreenShares(in: room)
    }
  }

  func room(
    _: Room,
    participant: RemoteParticipant,
    didFailToSubscribeTrackWithSid trackSid: Track.Sid,
    error: LiveKitError
  ) {
    log.warning(
      "GRID_ENGINE phase=livekit_remote_track_subscribe_failed handle=\(handle.id) participant=\(identity(of: participant)) track=\(trackSid) error=\(error)"
    )
  }

  func room(
    _: Room,
    participant: LocalParticipant,
    remoteDidSubscribeTrack publication: LocalTrackPublication
  ) {
    log.debug(
      "GRID_ENGINE phase=livekit_local_track_remote_subscribed handle=\(handle.id) track=\(publication.sid) kind=\(publication.kind) source=\(publication.source)"
    )
  }

  func room(_: Room, didDisconnectWithError error: LiveKitError?) {
    emitLifecycle(.disconnected(error: error.map(String.init(describing:))))
  }

  func room(_: Room, didStartReconnectWithMode mode: ReconnectMode) {
    emitLifecycle(.reconnecting(mode: gridReconnectMode(mode)))
  }

  func room(_: Room, didUpdateReconnectMode mode: ReconnectMode) {
    // LiveKit can begin with a quick reconnect and escalate to full before it
    // starts its detached local-track republish transaction. Forward the mode
    // update so the engine can install publication ownership fences in time.
    emitLifecycle(.reconnecting(mode: gridReconnectMode(mode)))
  }

  func room(_ room: Room, didCompleteReconnectWithMode mode: ReconnectMode) {
    emitLifecycle(.reconnected(mode: gridReconnectMode(mode)))
    emitParticipants(in: room)
    emitScreenShares(in: room)
  }

  func room(
    _ room: Room,
    participant _: LocalParticipant,
    didPublishTrack publication: LocalTrackPublication
  ) {
    switch publication.source {
    case .microphone:
      emitLifecycle(.localMicrophonePublished(muted: publication.isMuted))
    case .screenShareVideo:
      emitScreenShares(in: room)
    default:
      break
    }
  }

  func room(
    _ room: Room,
    participant _: LocalParticipant,
    didUnpublishTrack publication: LocalTrackPublication
  ) {
    switch publication.source {
    case .microphone:
      emitLifecycle(.localMicrophoneUnpublished)
    case .screenShareVideo:
      emitScreenShares(in: room)
    default:
      break
    }
  }

  private func emitParticipants(in room: Room) {
    var participants: [InlineRTCParticipant] = []
    if let identity = room.localParticipant.identity?.stringValue {
      participants.append(
        InlineRTCParticipant(
          identity: identity,
          isSpeaking: room.localParticipant.isSpeaking,
          audioLevel: room.localParticipant.isSpeaking ? room.localParticipant.audioLevel : 0
        )
      )
    }
    for participant in room.remoteParticipants.values {
      guard let identity = participant.identity?.stringValue else { continue }
      participants.append(
        InlineRTCParticipant(
          identity: identity,
          isSpeaking: participant.isSpeaking,
          audioLevel: participant.isSpeaking ? participant.audioLevel : 0
        )
      )
    }
    participants.sort { $0.identity < $1.identity }
    participantContinuation.yield(
      GridRTCParticipantSnapshotEnvelope(room: handle, participants: participants)
    )
  }

  private func emitScreenShares(in room: Room) {
    let snapshotMetadata = localScreenShareLock.withLock {
      screenShareSnapshotRevision &+= 1
      return (
        revision: screenShareSnapshotRevision,
        localCaptureSourceID: localScreenCaptureSourceID
      )
    }
    var shares: [InlineRTCScreenShare] = []
    if let identity = room.localParticipant.identity?.stringValue {
      shares.append(contentsOf: screenShares(
        for: room.localParticipant,
        identity: identity,
        isLocal: true,
        captureSourceID: snapshotMetadata.localCaptureSourceID
      ))
    }
    for participant in room.remoteParticipants.values {
      guard let identity = participant.identity?.stringValue else { continue }
      shares.append(contentsOf: screenShares(
        for: participant,
        identity: identity,
        isLocal: false,
        captureSourceID: nil
      ))
    }
    shares.sort { lhs, rhs in
      if lhs.participantIdentity != rhs.participantIdentity {
        return lhs.participantIdentity < rhs.participantIdentity
      }
      return lhs.publicationID < rhs.publicationID
    }
    emitLifecycle(
      .screenSharesChanged(
        revision: snapshotMetadata.revision,
        shares: shares
      )
    )
  }

  private func screenShares(
    for participant: Participant,
    identity: String,
    isLocal: Bool,
    captureSourceID: String?
  ) -> [InlineRTCScreenShare] {
    participant.videoTracks.compactMap { publication in
      guard publication.source == .screenShareVideo, !publication.isMuted else { return nil }
      return InlineRTCScreenShare(
        participantIdentity: identity,
        publicationID: String(describing: publication.sid),
        captureSourceID: captureSourceID,
        isLocal: isLocal,
        videoTrack: publication.track as? VideoTrack
      )
    }
  }

  func setOutputVolume(_ volume: Double) {
    let tracks = remoteFlowLock.withLock {
      outputVolume = volume
      return remoteFlowProbes.values.compactMap(\.track)
    }
    for track in tracks {
      track.volume = volume
    }
  }

  private func emitLifecycle(_ event: GridRTCLifecycleEvent) {
    lifecycleContinuation.yield(GridRTCLifecycleEventEnvelope(room: handle, event: event))
  }

  private func updateRemoteFlowMonitoring() {
    let contexts = remoteFlowLock.withLock { Array(remoteFlowProbes) }
    for (key, context) in contexts {
      if context.participant?.isSpeaking == true,
         context.publication?.isMuted == false {
        scheduleRemoteFlowCheck(key: key, context: context, reason: "speaking")
      } else {
        stopRemoteFlowMonitoring(key: key, context: context)
      }
    }
  }

  private func scheduleRemoteFlowCheck(
    key: String,
    context: RemoteFlowContext,
    reason: String
  ) {
    guard context.participant?.isSpeaking == true,
          context.publication?.isMuted == false
    else {
      stopRemoteFlowMonitoring(key: key, context: context)
      return
    }
    let checkID = UUID()
    let baseline = context.probe.snapshot()
    let interval = remoteFlowCheckInterval
    let task = Task { [weak self] in
      try? await Task.sleep(
        for: .milliseconds(Int(max(interval, 0) * 1_000))
      )
      guard !Task.isCancelled else { return }
      self?.reportRemoteFlow(
        key: key,
        context: context,
        checkID: checkID,
        baseline: baseline,
        reason: reason
      )
    }
    let assignment = remoteFlowLock.withLock { () -> (Bool, Task<Void, Never>?) in
      guard remoteFlowProbes[key] === context else { return (false, nil) }
      let oldTask = context.checkTask
      context.checkID = checkID
      context.checkTask = task
      return (true, oldTask)
    }
    assignment.1?.cancel()
    if !assignment.0 { task.cancel() }
  }

  private func reportRemoteFlow(
    key: String,
    context: RemoteFlowContext,
    checkID: UUID,
    baseline: GridAudioFlowProbe.Snapshot,
    reason: String
  ) {
    guard context.participant?.isSpeaking == true,
          context.publication?.isMuted == false
    else {
      stopRemoteFlowMonitoring(key: key, context: context)
      return
    }
    let snapshot = context.probe.snapshot()
    let frameDelta = snapshot.frameCount &- baseline.frameCount
    let result = remoteFlowLock.withLock { () -> (InlineRTCAudioFlowState?, Bool) in
      guard remoteFlowProbes[key] === context, context.checkID == checkID else {
        return (nil, false)
      }
      context.checkTask = nil
      context.checkID = nil
      if frameDelta > 0 {
        context.consecutiveMisses = 0
        guard context.state != .flowing else { return (nil, true) }
        context.state = .flowing
        return (.flowing, true)
      }
      context.consecutiveMisses += 1
      guard context.consecutiveMisses >= remoteFlowMissThreshold,
            context.state != .missing
      else { return (nil, false) }
      context.state = .missing
      return (.missing, false)
    }
    if result.1 {
      emitLifecycle(.remoteAudioFramesObserved(identity: context.identity))
    }
    let nextState = result.0
    if let nextState {
      emitLifecycle(.remoteAudioFlow(identity: context.identity, state: nextState))
      if nextState == .missing {
        log.warning(
          "GRID_ENGINE phase=livekit_remote_audio_flow_missing handle=\(handle.id) participant=\(context.identity) reason=\(reason) format=\(snapshot.sampleFormat)"
        )
      } else {
        log.debug(
          "GRID_ENGINE phase=livekit_remote_audio_flow_confirmed handle=\(handle.id) participant=\(context.identity) reason=\(reason) frames=\(frameDelta) format=\(snapshot.sampleFormat)"
        )
      }
    }
    scheduleRemoteFlowCheck(key: key, context: context, reason: "lifetime")
  }

  private func stopRemoteFlowMonitoring(key: String, context: RemoteFlowContext) {
    let shouldEmitUnknown = remoteFlowLock.withLock { () -> Bool in
      guard remoteFlowProbes[key] === context else { return false }
      context.checkTask?.cancel()
      context.checkTask = nil
      context.checkID = nil
      context.consecutiveMisses = 0
      guard context.state != .unknown else { return false }
      context.state = .unknown
      return true
    }
    if shouldEmitUnknown {
      emitLifecycle(.remoteAudioFlow(identity: context.identity, state: .unknown))
    }
  }

  private func identity(of participant: RemoteParticipant) -> String {
    participant.identity?.stringValue ?? "unknown"
  }

  private func gridReconnectMode(_ mode: ReconnectMode) -> GridRTCReconnectMode {
    switch mode {
    case .quick: .quick
    case .full: .full
    }
  }
}

private final class RemoteFlowContext: @unchecked Sendable {
  weak var track: RemoteAudioTrack?
  weak var publication: RemoteTrackPublication?
  weak var participant: RemoteParticipant?
  let identity: String
  let probe: GridAudioFlowProbe
  var state: InlineRTCAudioFlowState = .unknown
  var consecutiveMisses = 0
  var checkID: UUID?
  var checkTask: Task<Void, Never>?

  init(
    track: RemoteAudioTrack,
    publication: RemoteTrackPublication,
    participant: RemoteParticipant,
    identity: String,
    probe: GridAudioFlowProbe
  ) {
    self.track = track
    self.publication = publication
    self.participant = participant
    self.identity = identity
    self.probe = probe
  }
}

private enum LiveKitGridRTCDriverError: LocalizedError {
  case roomNotFound
  case roomLocallyRetired
  case microphoneNotPublished
  case audioProcessingPolicyNotEffective(String)
  case screenSharingUnavailable
  case invalidScreenCaptureSource
  case screenSharePublicationTransitioning

  var errorDescription: String? {
    switch self {
    case .roomNotFound:
      "The Grid room is no longer available."
    case .roomLocallyRetired:
      "The Grid room is already releasing local media."
    case .microphoneNotPublished:
      "The microphone is not published."
    case let .audioProcessingPolicyNotEffective(details):
      "WebRTC did not make Grid's software audio processing effective. \(details)"
    case .screenSharingUnavailable:
      "Screen sharing is unavailable on this Mac."
    case .invalidScreenCaptureSource:
      "The selected display is no longer available."
    case .screenSharePublicationTransitioning:
      "Screen sharing is reconnecting. Try again in a moment."
    }
  }
}
