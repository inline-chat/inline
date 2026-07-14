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
    let track: LocalAudioTrack
    if let cachedTrack = context.microphoneTrack,
       isPublished(cachedTrack, in: context) {
      if initiallyMuted {
        try await cachedTrack.mute()
        stopLocalFlowMonitoring(in: room, context: context)
      } else {
        let baseline = context.microphoneFlowProbe?.snapshot()
        try await cachedTrack.unmute()
        if let probe = context.microphoneFlowProbe, let baseline {
          scheduleLocalFlowCheck(
            in: room,
            probe: probe,
            baseline: baseline,
            reason: "republish_unmute",
            delay: context.configuration.connection.localAudioFlowStartupTimeout
          )
        }
      }
      return
    } else if let cachedTrack = context.microphoneTrack {
      track = cachedTrack
      log.warning(
        "GRID_ENGINE phase=livekit_microphone_publication_stale handle=\(room.id) action=republish_cached_track"
      )
    } else {
      track = LocalAudioTrack.createTrack(
        options: context.configuration.makeRoomOptions().defaultAudioCaptureOptions
      )
      let flowProbe = GridAudioFlowProbe()
      track.add(audioRenderer: flowProbe)
      context.microphoneFlowProbe = flowProbe
      context.microphoneTrack = track
      log.debug(
        "GRID_ENGINE phase=livekit_microphone_created handle=\(room.id) initially_muted=\(initiallyMuted)"
      )
    }

    // Establish the muted state before capture starts or signaling can publish
    // the track. No enabled pre-publication frame can reach another participant.
    if initiallyMuted {
      try await track.mute()
    }
    let startedAt = Date()
    log.debug(
      "GRID_ENGINE phase=livekit_microphone_publish_started handle=\(room.id) muted=\(track.isMuted)"
    )
    _ = try await context.room.localParticipant.publish(
      audioTrack: track,
      options: context.configuration.makeRoomOptions().defaultAudioPublishOptions
    )
    log.debug(
      "GRID_ENGINE phase=livekit_microphone_publish_finished handle=\(room.id) elapsed_ms=\(Self.elapsedMilliseconds(since: startedAt)) muted=\(track.isMuted)"
    )
    if !track.isMuted, let flowProbe = context.microphoneFlowProbe {
      scheduleLocalFlowCheck(
        in: room,
        probe: flowProbe,
        baseline: .init(frameCount: 0, sampleFormat: 0),
        reason: "publish",
        delay: context.configuration.connection.localAudioFlowStartupTimeout
      )
    }
  }

  func setMicrophoneMuted(_ muted: Bool, in room: GridRTCRoomHandle) async throws {
    let context = try context(for: room)
    guard let track = context.microphoneTrack else {
      throw LiveKitGridRTCDriverError.microphoneNotPublished
    }
    let baseline = context.microphoneFlowProbe?.snapshot()
    if muted {
      try await track.mute()
      stopLocalFlowMonitoring(in: room, context: context)
    } else {
      try await track.unmute()
    }
    log.debug(
      "GRID_ENGINE phase=livekit_microphone_mute_applied handle=\(room.id) muted=\(muted)"
    )
    if !muted, let probe = context.microphoneFlowProbe, let baseline {
      scheduleLocalFlowCheck(
        in: room,
        probe: probe,
        baseline: baseline,
        reason: "unmute",
        delay: context.configuration.connection.localAudioFlowStartupTimeout
      )
    }
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
    if let track = context.microphoneTrack, let probe = context.microphoneFlowProbe {
      track.remove(audioRenderer: probe)
    }
    log.debug(
      "GRID_ENGINE phase=livekit_disconnect_finished handle=\(room.id) elapsed_ms=\(Self.elapsedMilliseconds(since: startedAt))"
    )
  }

  private func context(for room: GridRTCRoomHandle) throws -> RoomContext {
    guard let context = rooms[room] else {
      throw LiveKitGridRTCDriverError.roomNotFound
    }
    return context
  }

  private func isPublished(_ track: LocalAudioTrack, in context: RoomContext) -> Bool {
    context.room.localParticipant.localAudioTracks.contains { publication in
      publication.track === track
    }
  }

  private func scheduleLocalFlowCheck(
    in room: GridRTCRoomHandle,
    probe: GridAudioFlowProbe,
    baseline: GridAudioFlowProbe.Snapshot,
    reason: String,
    delay: TimeInterval
  ) {
    guard let context = rooms[room], context.microphoneTrack?.isMuted == false else { return }
    context.localFlowCheckTask?.cancel()
    context.localFlowCheckTask = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(Int(max(delay, 0) * 1_000)))
      guard !Task.isCancelled else { return }
      await self?.reportLocalFlow(
        in: room,
        probe: probe,
        baseline: baseline,
        reason: reason
      )
    }
  }

  private func reportLocalFlow(
    in room: GridRTCRoomHandle,
    probe: GridAudioFlowProbe,
    baseline: GridAudioFlowProbe.Snapshot,
    reason: String
  ) {
    guard let context = rooms[room],
          context.microphoneFlowProbe === probe,
          context.microphoneTrack?.isMuted == false
    else { return }
    context.localFlowCheckTask = nil
    let snapshot = probe.snapshot()
    let frameDelta = snapshot.frameCount &- baseline.frameCount
    if frameDelta == 0 {
      log.warning(
        "GRID_ENGINE phase=livekit_local_audio_flow_missing handle=\(room.id) reason=\(reason) format=\(snapshot.sampleFormat)"
      )
      emitLocalFlow(.missing, in: room)
    } else {
      log.debug(
        "GRID_ENGINE phase=livekit_local_audio_flow_confirmed handle=\(room.id) reason=\(reason) frames=\(frameDelta) format=\(snapshot.sampleFormat)"
      )
      emitLocalFlow(.flowing, in: room)
    }
    scheduleLocalFlowCheck(
      in: room,
      probe: probe,
      baseline: snapshot,
      reason: "lifetime",
      delay: context.configuration.connection.localAudioFlowCheckInterval
    )
  }

  private func stopLocalFlowMonitoring(
    in room: GridRTCRoomHandle,
    context: RoomContext
  ) {
    context.localFlowCheckTask?.cancel()
    context.localFlowCheckTask = nil
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
  var microphoneFlowProbe: GridAudioFlowProbe?
  var localFlowCheckTask: Task<Void, Never>?

  init(
    room: Room,
    delegate: LiveKitGridRoomDelegate,
    configuration: InlineRTCConfiguration
  ) {
    self.room = room
    self.delegate = delegate
    self.configuration = configuration
  }
}

private final class LiveKitGridRoomDelegate: NSObject, RoomDelegate, @unchecked Sendable {
  private let handle: GridRTCRoomHandle
  private let lifecycleContinuation: AsyncStream<GridRTCLifecycleEventEnvelope>.Continuation
  private let participantContinuation: AsyncStream<GridRTCParticipantSnapshotEnvelope>.Continuation
  private let remoteFlowCheckInterval: TimeInterval
  private let remoteFlowMissThreshold: Int
  private let log = Log.scoped("LiveKitGridRoomDelegate")
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
  }

  func room(_ room: Room, participantDidDisconnect _: RemoteParticipant) {
    emitParticipants(in: room)
  }

  func room(
    _: Room,
    participant: RemoteParticipant,
    didPublishTrack publication: RemoteTrackPublication
  ) {
    log.debug(
      "GRID_ENGINE phase=livekit_remote_track_announced handle=\(handle.id) participant=\(identity(of: participant)) track=\(publication.sid) kind=\(publication.kind) source=\(publication.source)"
    )
  }

  func room(
    _: Room,
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
  }

  func room(
    _: Room,
    participant: Participant,
    trackPublication: TrackPublication,
    didUpdateIsMuted isMuted: Bool
  ) {
    guard let remoteParticipant = participant as? RemoteParticipant,
          let publication = trackPublication as? RemoteTrackPublication
    else { return }
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
    _: Room,
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

  func room(_: Room, didCompleteReconnectWithMode mode: ReconnectMode) {
    emitLifecycle(.reconnected(mode: gridReconnectMode(mode)))
  }

  func room(
    _: Room,
    participant _: LocalParticipant,
    didPublishTrack publication: LocalTrackPublication
  ) {
    guard publication.source == .microphone else { return }
    emitLifecycle(.localMicrophonePublished(muted: publication.isMuted))
  }

  func room(
    _: Room,
    participant _: LocalParticipant,
    didUnpublishTrack publication: LocalTrackPublication
  ) {
    guard publication.source == .microphone else { return }
    emitLifecycle(.localMicrophoneUnpublished)
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
    let nextState = remoteFlowLock.withLock { () -> InlineRTCAudioFlowState? in
      guard remoteFlowProbes[key] === context, context.checkID == checkID else { return nil }
      context.checkTask = nil
      context.checkID = nil
      if frameDelta > 0 {
        context.consecutiveMisses = 0
        guard context.state != .flowing else { return nil }
        context.state = .flowing
        return .flowing
      }
      context.consecutiveMisses += 1
      guard context.consecutiveMisses >= remoteFlowMissThreshold,
            context.state != .missing
      else { return nil }
      context.state = .missing
      return .missing
    }
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

private enum LiveKitGridRTCDriverError: Error {
  case roomNotFound
  case microphoneNotPublished
}
