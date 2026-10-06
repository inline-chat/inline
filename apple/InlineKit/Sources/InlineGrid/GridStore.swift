import Auth
import Foundation
import InlineKit
#if os(iOS)
import InlineAudioPlayback
#endif
import InlineProtocol
import InlineRTC
import Logger
import Observation
import RealtimeV2

@MainActor
@Observable
public final class GridRoomService {
  public private(set) var grids: [Int64: InlineProtocol.Grid] = [:]
  public private(set) var enabledSpaceIDs = Set<Int64>()
  public private(set) var homeSpaces: [GridHomeSpace] = []
  public private(set) var currentCall: GridCurrentCall?
  public private(set) var callTransferEnabled = false
  public private(set) var membershipMutationInFlight = false
  private var localAdmission: GridLocalAdmission?
  public var hasLocalAdmission: Bool {
    localAdmission != nil
  }

  public var mediaSessionIdentity: String? {
    currentMediaTarget()?.rtcSessionID.rawValue
  }

  public private(set) var loadingSpaceIDs = Set<Int64>()
  public private(set) var failedLoadSpaceIDs = Set<Int64>()
  public private(set) var lastError: String?
  public private(set) var networkRefreshRevision = 0
  public private(set) var networkAvailable = true
  public private(set) var pendingTranscriptionRequestIDs: [Int64: String] = [:]
  public var connectionRecoveryAttempt: Int {
    media.recoveryAttempt
  }

  public let media: GridMediaPresentation

  public var inputSelection: AudioInputSelection {
    get { media.inputSelection }
    set { mediaCoordinator.setInput(newValue) }
  }

  public var outputSelection: AudioOutputSelection {
    get { media.outputSelection }
    set { mediaCoordinator.setOutput(newValue) }
  }

  public var autoUnmuteOnJoin: Bool {
    get { media.autoUnmuteOnJoin }
    set { mediaCoordinator.setAutoUnmuteOnJoin(newValue) }
  }

  public var autoMuteWhenAlone: Bool {
    get { media.autoMuteWhenAlone }
    set {
      mediaCoordinator.setAutoMuteWhenAlone(newValue)
      reconcileAloneAutoMute()
    }
  }

  @ObservationIgnored private var platformEffects = GridPlatformEffects()
  @ObservationIgnored private let realtime: RealtimeV2
  @ObservationIgnored private let auth: AuthHandle
  @ObservationIgnored private var authAuthorityObserver: NSObjectProtocol?
  @ObservationIgnored private var localIntentRevision = 0
  @ObservationIgnored private var selfReadEpoch = 0
  @ObservationIgnored private var selfReadSequence = 0
  @ObservationIgnored private var lastAcceptedSelfReadSequence = 0
  @ObservationIgnored private var cancelPendingMembershipClaim = false
  @ObservationIgnored private var retentionTask: Task<Void, Never>?
  @ObservationIgnored private var pendingRetention: (eligible: Bool, accountToken: AuthAccountMutationToken)?
  @ObservationIgnored private var lastRetainedMediaEligible = false
  @ObservationIgnored private let api: GridRoomAPI
  @ObservationIgnored private let avatarStateSync: GridAvatarStateSync
  @ObservationIgnored private let membershipSync: GridMembershipSync
  @ObservationIgnored private let mediaCoordinator: GridMediaCoordinator
  @ObservationIgnored private let homePreferences: GridHomePreferences
  @ObservationIgnored private var lifecycleTask: Task<Void, Never>?
  @ObservationIgnored private var mediaEventsTask: Task<Void, Never>?
  @ObservationIgnored private var membershipEventsTask: Task<Void, Never>?
  @ObservationIgnored private var lastNetworkPathSnapshot: GridNetworkPathSnapshot?
  @ObservationIgnored private let lifecycle: GridRoomLifecycle
  @ObservationIgnored private var pendingReloadSpaceIDs = Set<Int64>()
  @ObservationIgnored private var pendingConnectionSpaceIDs = Set<Int64>()
  @ObservationIgnored private var roomMutationRevisions: [OptimisticRoomMutationKey: Int] = [:]
  @ObservationIgnored private var pendingRoomMutations: [OptimisticRoomMutationKey: OptimisticRoomMutation] = [:]
  @ObservationIgnored private var membershipMutationRevision = 0
  @ObservationIgnored private var retiredMembershipRevision = 0
  @ObservationIgnored private var pendingMembershipMutations: [Int: OptimisticMembershipMutation] = [:]
  @ObservationIgnored private var membershipRollbackBaseline =
    GridOptimisticState.MembershipRollbackBaseline()
  @ObservationIgnored private var acceptedOwnedRoom: GridOwnedRoomAuthority?
  @ObservationIgnored private var lastAcceptedSnapshotRevisions: [Int64: Int64] = [:]
  @ObservationIgnored private var spaceAccessRevisions: [Int64: Int] = [:]
  @ObservationIgnored private var homeLoadRevision = 0
  @ObservationIgnored private var lastRealtimeConnectionState: RealtimeConnectionState?
  @ObservationIgnored private var pendingCredentialTarget: GridMediaTarget?
  @ObservationIgnored private var credentialRetryTask: Task<Void, Never>?
  @ObservationIgnored private var credentialRetryTarget: GridMediaTarget?
  @ObservationIgnored private var credentialRetryAttempt = 0
  @ObservationIgnored private var aloneAutoMuteTask: Task<Void, Never>?
  @ObservationIgnored private var aloneAutoMuteTarget: GridAloneAutoMuteTarget?
  @ObservationIgnored private var screenShareAloneTask: Task<Void, Never>?
  @ObservationIgnored private var screenShareAloneTarget: GridScreenShareAloneTarget?
  @ObservationIgnored private var screenShareAloneGrace = GridScreenShareAloneGraceState()
  @ObservationIgnored private var screenShareNotificationTarget: GridMediaTarget?
  @ObservationIgnored private var observedRemoteScreenShares: [String: GridScreenShareNotice] = [:]
  @ObservationIgnored private var hasPrimedScreenSharePresentationEdges = false
  @ObservationIgnored private var pendingScreenShareOpenTasks:
    [String: GridPendingScreenShareOpen] = [:]
  @ObservationIgnored private var mediaInteractionStartedAt: Date?
  @ObservationIgnored private let log = Log.scoped("GridRoomService")
  private static let aloneMediaGraceSeconds = 5

  init(
    realtime: RealtimeV2 = Api.realtime,
    userDefaults: UserDefaults = .standard,
    engine: InlineRTCSession,
    auth: AuthHandle = Auth.shared.handle,
    sendGridTransaction: GridRoomAPI.Send? = nil
  ) {
    self.realtime = realtime
    self.auth = auth
    let api = GridRoomAPI(realtime: realtime, auth: auth, send: sendGridTransaction)
    self.api = api
    avatarStateSync = GridAvatarStateSync(api: api)
    let membershipSync = GridMembershipSync(api: api, auth: auth)
    self.membershipSync = membershipSync
    let networkMonitor = GridNetworkMonitor()
    lifecycle = GridRoomLifecycle(realtime: realtime, network: networkMonitor)
    let inputPreferences = AudioInputPreferenceStore(
      defaults: userDefaults,
      deviceIDKey: "grid.preferredInputDeviceID",
      deviceNameKey: "grid.preferredInputDeviceName"
    )
    let outputPreferences = AudioOutputPreferenceStore(
      defaults: userDefaults,
      deviceIDKey: "grid.preferredOutputDeviceID",
      deviceNameKey: "grid.preferredOutputDeviceName"
    )
    homePreferences = GridHomePreferences(defaults: userDefaults)
    let mediaCoordinator = GridMediaCoordinator(
      engine: engine,
      defaults: userDefaults,
      inputPreferences: inputPreferences,
      outputPreferences: outputPreferences
    )
    self.mediaCoordinator = mediaCoordinator
    media = mediaCoordinator.presentation
    authAuthorityObserver = auth.observeAccountAuthorityWillChange { [weak self] retirement in
      self?.retireAdmission(for: retirement)
    }
    lifecycleTask = Task { [weak self, lifecycle] in
      for await event in lifecycle.subscribe() {
        guard !Task.isCancelled else { return }
        await self?.handle(event)
      }
    }
    mediaEventsTask = Task { [weak self, mediaCoordinator] in
      for await event in mediaCoordinator.subscribe() {
        guard !Task.isCancelled else { return }
        await self?.handle(event)
      }
    }
    membershipEventsTask = Task { [weak self, membershipSync] in
      for await event in membershipSync.subscribe() {
        guard !Task.isCancelled else { return }
        await self?.handle(event)
      }
    }
  }

  isolated deinit {
    if let authAuthorityObserver {
      NotificationCenter.default.removeObserver(authAuthorityObserver)
    }
    lifecycleTask?.cancel()
    mediaEventsTask?.cancel()
    membershipEventsTask?.cancel()
    credentialRetryTask?.cancel()
    aloneAutoMuteTask?.cancel()
    screenShareAloneTask?.cancel()
    retentionTask?.cancel()
    pendingScreenShareOpenTasks.values.forEach { $0.task.cancel() }
  }

  public func configurePlatformEffects(_ effects: GridPlatformEffects) {
    platformEffects = effects
    mediaCoordinator.configurePlatformEffects(effects)
  }

  public func clearLastError() {
    lastError = nil
  }

  public func isEnabled(spaceID: Int64) -> Bool {
    enabledSpaceIDs.contains(spaceID)
  }

  /// Ends this process's media authority immediately. It does not move or
  /// remove a call owned by another device.
  @discardableResult
  public func withdrawLocalAdmission() -> Task<GridMediaShutdownReceipt, Never> {
    localIntentRevision &+= 1
    selfReadEpoch &+= 1
    if membershipMutationInFlight {
      cancelPendingMembershipClaim = true
    }
    clearLocalAdmission()
    return mediaCoordinator.withdrawLocalMedia()
  }

  /// An older authority transition cannot withdraw a call admitted by a newer login.
  private func retireAdmission(for retirement: AuthAccountAuthorityRetirement) {
    guard retirement.isCurrent,
          localAdmission == nil || localAdmission?.accountToken == retirement.previousAccount
    else { return }
    // Submission is synchronous. Waiting for this receipt cannot enqueue a second shutdown
    // after logout and a successor admission have overtaken this authority transition.
    let receipt = withdrawLocalAdmission()
    // A held RPC cannot keep the old account's worker slot or claim gate. Restore only the
    // confirmed display baseline; neither rollback nor a failed login readmits local media.
    if let pending = pendingMembershipMutations[membershipMutationRevision] {
      rollbackMembershipMutation(pending)
    }
    membershipMutationRevision &+= 1
    retiredMembershipRevision = membershipMutationRevision
    membershipMutationInFlight = false
    cancelPendingMembershipClaim = false
    pendingMembershipMutations.removeAll()
    membershipRollbackBaseline.clear()
    membershipSync.reset()
    retirement.requireRetirement(Task { await receipt.value.isLocallyQuiescent })
  }

  public func prepareForLogout() async {
    withdrawLocalAdmission()
    currentCall = nil
    callTransferEnabled = false
    membershipMutationInFlight = false
    cancelPendingMembershipClaim = false
    let invalidatedSpaceIDs = Set(spaceAccessRevisions.keys)
      .union(grids.keys)
      .union(enabledSpaceIDs)
      .union(loadingSpaceIDs)
      .union(pendingReloadSpaceIDs)
      .union(pendingConnectionSpaceIDs)
    pendingCredentialTarget = nil
    resetCredentialRetry()
    cancelAloneAutoMute()
    resetScreenShareAloneGrace()
    resetScreenSharePresentationEdges()
    grids.removeAll()
    homeSpaces.removeAll()
    enabledSpaceIDs.removeAll()
    loadingSpaceIDs.removeAll()
    failedLoadSpaceIDs.removeAll()
    pendingReloadSpaceIDs.removeAll()
    pendingConnectionSpaceIDs.removeAll()
    for spaceID in invalidatedSpaceIDs {
      spaceAccessRevisions[spaceID, default: 0] &+= 1
    }
    homeLoadRevision &+= 1
    roomMutationRevisions.removeAll()
    pendingRoomMutations.removeAll()
    pendingTranscriptionRequestIDs.removeAll()
    membershipMutationRevision &+= 1
    retiredMembershipRevision = membershipMutationRevision
    pendingMembershipMutations.removeAll()
    membershipRollbackBaseline.clear()
    lastAcceptedSnapshotRevisions.removeAll()
    acceptedOwnedRoom = nil
    membershipSync.reset()
    avatarStateSync.setOwnedRoom(nil)
    await mediaCoordinator.shutdown()
  }

  public func grid(spaceID: Int64) -> InlineProtocol.Grid? {
    grids[spaceID]
  }

  public var activeTranscriptionRoom: GridRoom? {
    grids.values.lazy.compactMap { grid in
      guard grid.hasCurrentRoomID,
            let room = grid.rooms.first(where: { $0.id == grid.currentRoomID }),
            room.transcriptionIsRunning,
            room.avatars.contains(where: { $0.ownedByCurrentSession && !$0.membershipID.isEmpty })
      else { return nil }
      return room
    }.first
  }

  public func recentAvatars(spaceID: Int64, limit: Int = 4) -> [GridAvatar] {
    guard let grid = grids[spaceID] else { return [] }
    return Array(
      grid.rooms
        .flatMap(\.avatars)
        .sorted { $0.joinedAt > $1.joinedAt }
        .prefix(limit)
    )
  }

  public func loadHome() async {
    guard realtimeReady else {
      log.debug("GRID_TRACE phase=home_load_deferred reason=realtime_not_ready")
      return
    }
    homeLoadRevision &+= 1
    let revision = homeLoadRevision
    do {
      guard let read = beginSelfRead() else { return }
      let response = try await api.home(accountToken: read.accountToken)
      guard revision == homeLoadRevision, isCurrent(read) else { return }
      applySelfRead(response.currentCall, capability: response.callTransferEnabled, fence: read)
      let nextHomeSpaces = response.spaces
      let previouslyLoadedSpaceIDs = Set(grids.keys)
      homeSpaces = nextHomeSpaces
      let eligibleSpaceIDs = Set(homeSpaces.map(\.spaceID))
      enabledSpaceIDs = eligibleSpaceIDs
      for spaceID in previouslyLoadedSpaceIDs.subtracting(eligibleSpaceIDs) {
        clearLocalGrid(spaceID: spaceID, reason: "home_reconciliation")
      }
      lastError = nil
    } catch {
      guard revision == homeLoadRevision else { return }
      guard realtimeReady, networkAvailable else {
        log.debug("GRID_TRACE phase=home_load_deferred reason=connection_lost")
        return
      }
      lastError = String(describing: error)
      log.warning("GRID_TRACE phase=home_load_failed")
      PerformanceTrace.breadcrumb(
        "Grid Home discovery failed",
        category: "Grid.Home",
        level: .warning
      )
    }
  }

  public var orderedHomeSpaces: [GridHomeSpace] {
    homePreferences.ordered(homeSpaces)
  }

  public func recordGridOpened(spaceID: Int64) {
    homePreferences.recordOpened(spaceID: spaceID)
  }

  public func audioLevel(userID: Int64) -> Float {
    let legacyIdentity = Self.liveKitIdentityPrefix(userID: userID)
    return media.participantAudioLevels
      .filter { $0.key == legacyIdentity || $0.key.hasPrefix("\(legacyIdentity)-") }
      .map(\.value)
      .max() ?? 0
  }

  public func isScreenSharing(avatar: GridAvatar) -> Bool {
    if avatar.ownedByCurrentSession {
      return media.isScreenShareRequested
    }
    let identities = participantIdentities(for: avatar)
    let knownIntents = identities.compactMap { media.participantScreenShareIntents[$0] }
    if !knownIntents.isEmpty {
      return knownIntents.contains(true)
    }
    let shares = screenShares(avatar: avatar)
    return !shares.isEmpty
  }

  public func isScreenShareIntended(participantIdentity: String) -> Bool {
    if let intent = media.participantScreenShareIntents[participantIdentity] {
      return intent
    }
    return media.screenShares.contains { $0.participantIdentity == participantIdentity }
  }

  public func isScreenSharing(userID: Int64) -> Bool {
    let shares = screenShares(userID: userID)
    if isOwnedUser(userID) {
      return shares.contains(where: \.isLocal)
    }
    return !shares.isEmpty
  }

  public func screenShare(userID: Int64) -> InlineRTCScreenShare? {
    let shares = screenShares(userID: userID)
    if isOwnedUser(userID) {
      return shares.first(where: \.isLocal)
    }
    return shares.first
  }

  public func screenShare(avatar: GridAvatar) -> InlineRTCScreenShare? {
    let shares = screenShares(avatar: avatar)
    return avatar.ownedByCurrentSession
      ? shares.first(where: \.isLocal)
      : shares.first
  }

  public func screenShares(avatar: GridAvatar) -> [InlineRTCScreenShare] {
    let identities = participantIdentities(for: avatar)
    return media.screenShares.filter { identities.contains($0.participantIdentity) }
  }

  public func screenShares(userID: Int64) -> [InlineRTCScreenShare] {
    media.screenShares.filter {
      Self.identity($0.participantIdentity, matchesUserID: userID)
    }
  }

  public func screenShares(participantIdentity: String) -> [InlineRTCScreenShare] {
    media.screenShares.filter { $0.participantIdentity == participantIdentity }
  }

  public func screenShare(publicationID: String) -> InlineRTCScreenShare? {
    media.screenShares.first { $0.publicationID == publicationID }
  }

  public func load(spaceID: Int64) async {
    guard realtimeReady else {
      failedLoadSpaceIDs.remove(spaceID)
      pendingConnectionSpaceIDs.insert(spaceID)
      log.debug(
        "GRID_TRACE phase=load_deferred space=\(spaceID) reason=realtime_not_ready"
      )
      return
    }
    pendingConnectionSpaceIDs.remove(spaceID)
    let accessRevision = spaceAccessRevisions[spaceID, default: 0]
    guard loadingSpaceIDs.insert(spaceID).inserted else {
      pendingReloadSpaceIDs.insert(spaceID)
      return
    }
    failedLoadSpaceIDs.remove(spaceID)
    defer {
      loadingSpaceIDs.remove(spaceID)
      if pendingReloadSpaceIDs.remove(spaceID) != nil {
        Task { [weak self] in await self?.load(spaceID: spaceID) }
      }
    }

    do {
      let settings = try await api.settings(spaceID: spaceID)
      guard accessRevision == spaceAccessRevisions[spaceID, default: 0] else { return }
      applyEnabled(settings.gridEnabled, spaceID: spaceID)
      lastError = nil
      guard settings.gridEnabled else {
        reconcileMediaDemand()
        return
      }
      try await reloadGrid(spaceID: spaceID)
    } catch {
      guard accessRevision == spaceAccessRevisions[spaceID, default: 0] else { return }
      guard realtimeReady, networkAvailable else {
        pendingConnectionSpaceIDs.insert(spaceID)
        log.debug(
          "GRID_TRACE phase=load_deferred space=\(spaceID) reason=connection_lost"
        )
        return
      }
      failedLoadSpaceIDs.insert(spaceID)
      lastError = String(describing: error)
      log.error("GRID_TRACE phase=load_failed space=\(spaceID)", error: error)
      PerformanceTrace.breadcrumb(
        "Grid snapshot failed",
        category: "Grid.Snapshot",
        level: .error,
        data: ["space_id": spaceID]
      )
    }
  }

  public func setEnabled(_ enabled: Bool, spaceID: Int64) async throws {
    let accessRevision = spaceAccessRevisions[spaceID, default: 0]
    let settings = try await api.setEnabled(enabled, spaceID: spaceID)
    guard accessRevision == spaceAccessRevisions[spaceID, default: 0] else { return }
    applyEnabled(settings.gridEnabled, spaceID: spaceID)
    if enabled {
      try await reloadGrid(spaceID: spaceID)
    } else {
      reconcileMediaDemand()
    }
    await loadHome()
  }

  public func createAndJoin(spaceID: Int64) {
    guard let accountToken = beginMembershipClaim() else { return }
    let expectedMembershipID = observedMembershipFence()
    let startedAt = Date()
    #if os(iOS)
    mediaCoordinator.setMicrophoneEnabled(false)
    #endif
    let automaticMicrophoneChange = mediaCoordinator.applyAutoUnmuteOnJoin()
    #if os(macOS)
    mediaCoordinator.requestMicrophonePermission()
    #endif
    platformEffects.playSound?(.join)
    membershipMutationRevision &+= 1
    membershipSync.submit(GridMembershipOperation(
      kind: .create,
      spaceID: spaceID,
      expectedMembershipID: expectedMembershipID,
      intentRevision: localIntentRevision,
      accountToken: accountToken,
      microphoneEnabled: mediaCoordinator.isMicrophoneEnabled,
      automaticMicrophoneChange: automaticMicrophoneChange,
      accessRevision: spaceAccessRevisions[spaceID, default: 0],
      revision: membershipMutationRevision,
      startedAt: startedAt
    ))
  }

  public func join(roomID: Int64) {
    guard let destination = grids.values.first(where: { $0.rooms.contains(where: { $0.id == roomID }) }),
          let accountToken = beginMembershipClaim()
    else { return }
    let expectedMembershipID = observedMembershipFence()
    let startedAt = Date()
    mediaInteractionStartedAt = destination.rooms.first(where: { $0.id == roomID })?.avatars.isEmpty == false
      ? startedAt : nil
    #if os(iOS)
    mediaCoordinator.setMicrophoneEnabled(false)
    #endif
    let automaticMicrophoneChange = mediaCoordinator.applyAutoUnmuteOnJoin()
    guard let mutation = optimisticallyJoin(roomID: roomID) else {
      membershipMutationInFlight = false
      return
    }
    #if os(macOS)
    mediaCoordinator.requestMicrophonePermission()
    #endif
    platformEffects.playSound?(.join)
    pendingMembershipMutations[mutation.revision] = mutation
    membershipSync.submit(GridMembershipOperation(
      kind: .join(roomID: roomID),
      spaceID: mutation.spaceID,
      expectedMembershipID: expectedMembershipID,
      intentRevision: localIntentRevision,
      accountToken: accountToken,
      microphoneEnabled: mediaCoordinator.isMicrophoneEnabled,
      automaticMicrophoneChange: automaticMicrophoneChange,
      accessRevision: spaceAccessRevisions[mutation.spaceID, default: 0],
      revision: mutation.revision,
      startedAt: startedAt
    ))
  }

  /// Explicitly resumes a cold process or moves the same call from another
  /// device. Server ownership alone never admits media after browsing.
  public func moveCallHere() {
    guard callTransferEnabled, let call = currentCall,
          !membershipMutationInFlight,
          let accountToken = try? auth.beginAccountMutation()
    else { return }
    guard validateNativeAdmission() else { return }
    localIntentRevision &+= 1
    selfReadEpoch &+= 1
    clearLocalAdmission()
    membershipMutationInFlight = true
    cancelPendingMembershipClaim = false
    membershipMutationRevision &+= 1
    mediaCoordinator.setMicrophoneEnabled(false)
    membershipSync.submit(GridMembershipOperation(
      kind: .move(callID: call.callID, roomID: call.roomID),
      spaceID: call.spaceID,
      expectedMembershipID: call.membershipID,
      intentRevision: localIntentRevision,
      accountToken: accountToken,
      microphoneEnabled: false,
      automaticMicrophoneChange: nil,
      accessRevision: spaceAccessRevisions[call.spaceID, default: 0],
      revision: membershipMutationRevision,
      startedAt: Date()
    ))
  }

  public func leaveCurrentRoom(spaceID: Int64) {
    // A hanging claim must never make Leave or Cancel unable to stop locally.
    if membershipMutationInFlight {
      withdrawLocalAdmission()
      for spaceID in Array(grids.keys) {
        _ = optimisticallyLeave(spaceID: spaceID)
      }
      pendingMembershipMutations.removeAll()
      return
    }
    let membershipID = observedMembershipFence()
    let roomID = currentCall?.ownedByCurrentSession == true
      ? currentCall?.roomID : grids[spaceID]?.currentRoomID
    let isOwned = currentCall?.ownedByCurrentSession == true
      || grids[spaceID]?.rooms
      .contains(where: { $0.id == roomID && $0.avatars.contains(where: \.ownedByCurrentSession) }) == true
    guard isOwned, let roomID, !membershipID.isEmpty,
          let accountToken = try? auth.beginAccountMutation()
    else {
      withdrawLocalAdmission()
      return
    }
    withdrawLocalAdmission()
    cancelPendingMembershipClaim = false
    let mutation = optimisticallyLeave(spaceID: spaceID)
    if let mutation {
      pendingMembershipMutations[mutation.revision] = mutation
    }
    if mutation == nil {
      membershipMutationRevision &+= 1
    }
    membershipMutationInFlight = true
    platformEffects.playSound?(.leave)
    membershipSync.submit(GridMembershipOperation(
      kind: .leave(roomID: roomID),
      spaceID: spaceID,
      expectedMembershipID: membershipID,
      intentRevision: localIntentRevision,
      accountToken: accountToken,
      microphoneEnabled: false,
      automaticMicrophoneChange: nil,
      accessRevision: spaceAccessRevisions[spaceID, default: 0],
      revision: membershipMutationRevision,
      startedAt: Date()
    ))
  }

  private func beginMembershipClaim() -> AuthAccountMutationToken? {
    guard !membershipMutationInFlight,
          let token = try? auth.beginAccountMutation()
    else { return nil }
    #if os(iOS)
    guard callTransferEnabled else { return nil }
    #endif
    guard !callTransferEnabled || currentCall?.ownedByCurrentSession != false else {
      lastError = "Move your call here first"
      return nil
    }
    guard validateNativeAdmission() else { return nil }
    localIntentRevision &+= 1
    selfReadEpoch &+= 1
    clearLocalAdmission()
    membershipMutationInFlight = true
    cancelPendingMembershipClaim = false
    return token
  }

  private func validateNativeAdmission() -> Bool {
    #if os(iOS)
    do {
      try InlineAudioSession.shared.validateGridAdmission()
    } catch {
      lastError = error.localizedDescription
      return false
    }
    #endif
    lastError = nil
    return true
  }

  private func observedMembershipFence() -> String {
    if let currentCall {
      return currentCall.membershipID
    }
    return grids.values.lazy.flatMap(\.rooms).flatMap(\.avatars)
      .first(where: \.ownedByCurrentSession)?.membershipID ?? ""
  }

  public func toggleMicrophone(spaceID: Int64) {
    guard hasLocalAdmission, let grid = grids[spaceID], grid.hasCurrentRoomID,
          let room = grid.rooms.first(where: { $0.id == grid.currentRoomID }),
          room.avatars.contains(where: \.ownedByCurrentSession)
    else { return }
    let roomID = grid.currentRoomID
    let enabled = mediaCoordinator.toggleMicrophone()
    applyAvatarMicrophoneState(
      spaceID: spaceID,
      roomID: roomID,
      userID: nil,
      enabled: enabled
    )
    avatarStateSync.submitMicrophoneState(roomID: roomID, enabled: enabled)
    reconcileMediaDemand()
  }

  public func openRoomThread(roomID: Int64) async throws -> Int64 {
    let room = try transcriptionRoom(roomID: roomID)
    guard let avatar = room.avatars.first(where: \.ownedByCurrentSession), !avatar.membershipID.isEmpty else {
      throw GridRoomAPIError.invalidResponse
    }
    let chatID = try await api.openRoomThread(roomID: roomID, membershipID: avatar.membershipID)
    let latestRoom = try transcriptionRoom(roomID: roomID)
    guard latestRoom.avatars.contains(where: { $0.ownedByCurrentSession && $0.membershipID == avatar.membershipID })
    else {
      throw GridRoomAPIError.invalidResponse
    }
    // Thread sidecars are applied by the transaction before navigation.
    return chatID
  }

  public func setTranscription(
    room: GridRoom,
    enabled: Bool,
    destination: GridTranscriptionRequest.Destination = .last
  ) async throws {
    let roomID = room.id
    guard pendingTranscriptionRequestIDs[roomID] == nil else { throw GridRoomAPIError.invalidResponse }
    let latestRoom = try transcriptionRoom(roomID: roomID)
    guard let request = GridTranscriptionRequest(room: room, enabled: enabled, destination: destination) else {
      throw GridRoomAPIError.invalidResponse
    }
    guard latestRoom.avatars.contains(where: { $0.ownedByCurrentSession && $0.membershipID == request.membershipID }),
          latestRoom.hasConnection, latestRoom.connection.generation == request.generation
    else { throw GridRoomAPIError.invalidResponse }
    let accessRevision = spaceAccessRevisions[room.spaceID, default: 0]
    pendingTranscriptionRequestIDs[roomID] = request.requestID
    defer {
      if pendingTranscriptionRequestIDs[roomID] == request.requestID {
        pendingTranscriptionRequestIDs.removeValue(forKey: roomID)
      }
    }
    do {
      let grid = try await api.setTranscription(request: request)
      guard accessRevision == spaceAccessRevisions[room.spaceID, default: 0] else { return }
      applySnapshot([grid])
    } catch {
      // A rejected fence or uncertain response must repair from the authority,
      // never synthesize an active/stopped state in the client.
      if accessRevision == spaceAccessRevisions[room.spaceID, default: 0] {
        try? await reloadGrid(spaceID: room.spaceID)
      }
      throw error
    }
  }

  public func listTranscripts(roomID: Int64) async throws -> [GridTranscriptDestinationInfo] {
    let room = try transcriptionRoom(roomID: roomID)
    let membershipID = room.avatars.first(where: \.ownedByCurrentSession)?.membershipID
    let transcripts = try await api.listTranscripts(roomID: roomID)
    let latestRoom = try transcriptionRoom(roomID: roomID)
    guard latestRoom.avatars.contains(where: { $0.ownedByCurrentSession && $0.membershipID == membershipID }) else {
      throw GridRoomAPIError.invalidResponse
    }
    return transcripts
  }

  private func transcriptionRoom(roomID: Int64) throws -> GridRoom {
    guard let grid = grids.values.first(where: { $0.hasCurrentRoomID && $0.currentRoomID == roomID }),
          let room = grid.rooms.first(where: { $0.id == roomID }),
          room.avatars.contains(where: { $0.ownedByCurrentSession && !$0.membershipID.isEmpty })
    else { throw GridRoomAPIError.invalidResponse }
    return room
  }

  public func toggleCurrentMicrophone() {
    guard let grid = grids.values.first(where: { grid in
      guard grid.hasCurrentRoomID,
            let room = grid.rooms.first(where: { $0.id == grid.currentRoomID })
      else { return false }
      return room.avatars.contains(where: \.ownedByCurrentSession)
    }) else { return }

    toggleMicrophone(spaceID: grid.spaceID)
  }

  public func toggleScreenShare() {
    guard currentMediaTarget() != nil else { return }
    if media.isScreenShareRequested || media.isScreenSharing {
      mediaCoordinator.stopScreenSharing()
      resetScreenShareAloneGrace()
      return
    }
    let displayID = platformEffects.displayIDUnderPointer?()
    Task { [weak self] in
      guard let self else { return }
      await mediaCoordinator.startScreenSharing(displayID: displayID)
      reconcileScreenShareAloneGrace()
    }
  }

  public func startScreenSharing(_ source: InlineRTCScreenCaptureSource) {
    guard currentMediaTarget() != nil else { return }
    mediaCoordinator.startScreenSharing(source)
    reconcileScreenShareAloneGrace()
  }

  public func setScreenShareQualityProfile(_ profile: InlineRTCScreenShareQualityProfile) {
    mediaCoordinator.setScreenShareQualityProfile(profile)
  }

  public func stopScreenSharing() {
    mediaCoordinator.stopScreenSharing()
    resetScreenShareAloneGrace()
  }

  public func refreshScreenCaptureSources() {
    Task { [weak self] in
      await self?.mediaCoordinator.refreshScreenCaptureSources()
    }
  }

  public func openScreenShare(for avatar: GridAvatar) {
    guard let participantIdentity = screenShareParticipantIdentity(for: avatar) else { return }
    openScreenShare(
      user: avatar.user,
      participantIdentity: participantIdentity
    )
  }

  public func openScreenShareFromNotification(
    spaceID: Int64,
    roomID: Int64,
    userID: Int64,
    participantIdentity: String
  ) {
    Task { [weak self] in
      guard let self else { return }
      await load(spaceID: spaceID)
      guard let grid = grids[spaceID],
            let room = grid.rooms.first(where: { $0.id == roomID }),
            let avatar = room.avatars.first(where: { $0.user.id == userID })
      else { return }
      openScreenShare(
        user: avatar.user,
        participantIdentity: participantIdentity
      )
    }
  }

  public func toggleRoomLock(roomID: Int64, locked: Bool) async {
    guard let mutation = optimisticallyUpdateRoom(
      roomID: roomID,
      field: .locked,
      update: { $0.locked = locked }
    ) else { return }
    do {
      let grid = try await api.setLocked(locked, roomID: roomID)
      guard isCurrent(mutation) else { return }
      pendingRoomMutations.removeValue(forKey: mutation.key)
      applySnapshot([grid])
    } catch {
      guard isCurrent(mutation) else { return }
      rollbackRoomMutation(mutation)
      lastError = String(describing: error)
      if networkAvailable {
        try? await reloadGrid(spaceID: mutation.change.spaceID)
      }
    }
  }

  public func setRoomTitle(roomID: Int64, title: String) async {
    let normalizedTitle = title.split(whereSeparator: \Character.isWhitespace).joined(separator: " ")
    guard let mutation = optimisticallyUpdateRoom(
      roomID: roomID,
      field: .title,
      update: { room in
        if normalizedTitle.isEmpty {
          room.clearTitle()
        } else {
          room.title = normalizedTitle
        }
      }
    ) else { return }
    do {
      let grid = try await api.setTitle(title, roomID: roomID)
      guard isCurrent(mutation) else { return }
      pendingRoomMutations.removeValue(forKey: mutation.key)
      applySnapshot([grid])
    } catch {
      guard isCurrent(mutation) else { return }
      rollbackRoomMutation(mutation)
      lastError = String(describing: error)
      if networkAvailable {
        try? await reloadGrid(spaceID: mutation.change.spaceID)
      }
    }
  }

  public func deleteRoom(roomID: Int64) async {
    guard let spaceID = grids.first(where: { _, grid in
      grid.rooms.contains(where: { $0.id == roomID })
    })?.key else { return }
    let accessRevision = spaceAccessRevisions[spaceID, default: 0]
    do {
      let grid = try await api.deleteRoom(roomID: roomID)
      guard accessRevision == spaceAccessRevisions[spaceID, default: 0] else { return }
      applySnapshot([grid])
      await loadHome()
    } catch {
      lastError = String(describing: error)
    }
  }

  private func reloadGrid(spaceID: Int64, renewingMembershipID: String? = nil) async throws {
    let accessRevision = spaceAccessRevisions[spaceID, default: 0]
    guard let read = beginSelfRead() else { return }
    let response = try await api.grid(
      spaceID: spaceID,
      expectedMembershipID: renewingMembershipID,
      accountToken: read.accountToken
    )
    guard accessRevision == spaceAccessRevisions[spaceID, default: 0], isCurrent(read) else { return }
    applySnapshot([response.grid])
    applySelfRead(response.currentCall, capability: response.grid.callTransferEnabled, fence: read)
    syncMicrophoneStateIfNeeded(grid: response.grid)
    await prepareConnectionIfNeeded(grid: response.grid)
  }

  private func apply(grids nextGrids: [InlineProtocol.Grid], credentials: GridConnectionCredentials? = nil) async {
    applySnapshot(nextGrids)
    nextGrids.forEach(syncMicrophoneStateIfNeeded)
    if let credentials {
      await accept(credentials)
    }
  }

  private func applySnapshot(_ nextGrids: [InlineProtocol.Grid]) {
    for incomingGrid in nextGrids {
      let previousRevision = lastAcceptedSnapshotRevisions[incomingGrid.spaceID]
      if let previousRevision, incomingGrid.revision < previousRevision {
        log.debug(
          "GRID_TRACE phase=snapshot_rejected_stale space=\(incomingGrid.spaceID) incoming_revision=\(incomingGrid.revision) current_revision=\(previousRevision)"
        )
        continue
      }
      lastAcceptedSnapshotRevisions[incomingGrid.spaceID] = incomingGrid.revision
      // Record ownership before pending room/membership UI overlays.
      if incomingGrid.enabled,
         let room = incomingGrid.rooms.first(where: { $0.avatars.contains(where: \.ownedByCurrentSession) }),
         let avatar = room.avatars.first(where: \.ownedByCurrentSession), !avatar.membershipID.isEmpty
      {
        acceptedOwnedRoom = GridOwnedRoomAuthority(
          spaceID: incomingGrid.spaceID, roomID: room.id, membershipID: avatar.membershipID
        )
      } else if acceptedOwnedRoom?.spaceID == incomingGrid.spaceID {
        acceptedOwnedRoom = nil
      }
      var grid = incomingGrid
      for mutation in pendingRoomMutations.values where mutation.change.spaceID == grid.spaceID {
        grid = GridOptimisticState.applyingRoomIntent(mutation.change, to: grid)
      }
      grids[grid.spaceID] = grid
      failedLoadSpaceIDs.remove(grid.spaceID)
      pendingConnectionSpaceIDs.remove(grid.spaceID)
      applyEnabled(grid.enabled, spaceID: grid.spaceID)
    }
    applyPendingMembershipIntent()

    reconcileLocalAdmission()
    reconcileAvatarStateOwnership()
    reconcileMediaDemand()
  }

  private func reconcileMediaDemand() {
    let target = currentMediaTarget()
    if credentialRetryTarget != target {
      resetCredentialRetry()
    }
    if screenShareNotificationTarget != target {
      resetScreenSharePresentationEdges(target: target)
    }
    mediaCoordinator.setTarget(target)
    reconcileAloneAutoMute()
    reconcileScreenShareAloneGrace()
  }

  private func resetScreenSharePresentationEdges(target: GridMediaTarget? = nil) {
    pendingScreenShareOpenTasks.values.forEach { $0.task.cancel() }
    pendingScreenShareOpenTasks.removeAll()
    screenShareNotificationTarget = target
    observedRemoteScreenShares.removeAll()
    hasPrimedScreenSharePresentationEdges = false
  }

  private func reconcileScreenSharePresentationEdges() {
    guard let target = currentMediaTarget(),
          screenShareNotificationTarget == target,
          media.hasParticipantMediaSnapshot,
          let grid = grids[target.spaceID],
          let room = grid.rooms.first(where: { $0.id == target.roomID })
    else { return }

    var next: [String: GridScreenShareNotice] = [:]
    for avatar in room.avatars where !avatar.ownedByCurrentSession && isScreenSharing(avatar: avatar) {
      guard let participantIdentity = screenShareParticipantIdentity(for: avatar) else { continue }
      next[participantIdentity] = GridScreenShareNotice(
        target: target,
        user: avatar.user,
        participantIdentity: participantIdentity
      )
    }

    guard hasPrimedScreenSharePresentationEdges else {
      observedRemoteScreenShares = next
      hasPrimedScreenSharePresentationEdges = true
      return
    }

    let previous = observedRemoteScreenShares
    observedRemoteScreenShares = next
    for (identity, notice) in next where previous[identity] == nil {
      presentScreenShareChange(notice, started: true)
    }
    for (identity, notice) in previous where next[identity] == nil {
      pendingScreenShareOpenTasks.removeValue(forKey: identity)?.task.cancel()
      presentScreenShareChange(notice, started: false)
    }
  }

  private func presentScreenShareChange(
    _ notice: GridScreenShareNotice,
    started: Bool
  ) {
    platformEffects.presentScreenShareChange?(GridScreenShareChange(
      spaceID: notice.target.spaceID,
      roomID: notice.target.roomID,
      user: notice.user,
      participantIdentity: notice.participantIdentity,
      started: started
    ), self)
  }

  private func reconcileAloneAutoMute() {
    guard mediaCoordinator.shouldAutoMuteWhenAlone else {
      cancelAloneAutoMute()
      return
    }
    let target = grids.values.lazy.compactMap { grid -> GridAloneAutoMuteTarget? in
      guard grid.hasCurrentRoomID,
            let room = grid.rooms.first(where: { $0.id == grid.currentRoomID }),
            room.avatars.count == 1,
            let avatar = room.avatars.first,
            avatar.ownedByCurrentSession,
            avatar.microphoneEnabled,
            self.mediaCoordinator.isMicrophoneEnabled
      else { return nil }
      return GridAloneAutoMuteTarget(
        spaceID: grid.spaceID,
        roomID: room.id,
        userID: avatar.user.id
      )
    }.first

    guard target != aloneAutoMuteTarget else { return }
    cancelAloneAutoMute()
    guard let target else { return }

    aloneAutoMuteTarget = target
    aloneAutoMuteTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(Self.aloneMediaGraceSeconds))
      guard !Task.isCancelled else { return }
      self?.autoMuteIfStillAlone(target)
    }
  }

  private func autoMuteIfStillAlone(_ target: GridAloneAutoMuteTarget) {
    guard aloneAutoMuteTarget == target else { return }
    aloneAutoMuteTask = nil
    aloneAutoMuteTarget = nil

    guard mediaCoordinator.shouldAutoMuteWhenAlone,
          let grid = grids[target.spaceID],
          grid.hasCurrentRoomID,
          grid.currentRoomID == target.roomID,
          let room = grid.rooms.first(where: { $0.id == target.roomID }),
          room.avatars.count == 1,
          let avatar = room.avatars.first,
          avatar.ownedByCurrentSession,
          avatar.user.id == target.userID,
          avatar.microphoneEnabled,
          mediaCoordinator.isMicrophoneEnabled
    else { return }

    log.debug("GRID_TRACE phase=alone_auto_mute room=\(target.roomID)")
    toggleMicrophone(spaceID: target.spaceID)
  }

  private func cancelAloneAutoMute() {
    aloneAutoMuteTask?.cancel()
    aloneAutoMuteTask = nil
    aloneAutoMuteTarget = nil
  }

  private func reconcileScreenShareAloneGrace() {
    let context = screenShareAloneContext()
    let action = screenShareAloneGrace.reconcile(context)

    guard case let .scheduleStop(publicationIDs) = action,
          let mediaTarget = currentMediaTarget()
    else {
      cancelScreenShareAloneTask()
      return
    }

    let target = GridScreenShareAloneTarget(
      mediaTarget: mediaTarget,
      episodeID: context.episodeID,
      publicationIDs: publicationIDs
    )
    guard target != screenShareAloneTarget else { return }
    cancelScreenShareAloneTask()
    screenShareAloneTarget = target
    screenShareAloneTask = Task { [weak self] in
      try? await Task.sleep(for: GridScreenShareAloneGraceState.graceDuration)
      guard !Task.isCancelled else { return }
      self?.stopScreenShareIfStillAlone(target)
    }
  }

  private func screenShareAloneContext() -> GridScreenShareAloneGraceState.Context {
    let localShares = media.screenShares.filter(\.isLocal)
    let localPublicationIDs = Set(localShares.map(\.publicationID))
    let localParticipantIdentities = Set(localShares.map(\.participantIdentity))
    let hasRemoteParticipant = media.connectedParticipantIdentities.contains {
      !localParticipantIdentities.contains($0)
    }
    return .init(
      episodeID: media.screenShareEpisodeID,
      isConnected: media.connectionState == .connected,
      isShareRequested: media.isScreenShareRequested,
      localPublicationIDs: localPublicationIDs,
      hasRemoteParticipant: hasRemoteParticipant
    )
  }

  private func stopScreenShareIfStillAlone(_ target: GridScreenShareAloneTarget) {
    guard screenShareAloneTarget == target else { return }
    screenShareAloneTask = nil
    screenShareAloneTarget = nil
    guard currentMediaTarget() == target.mediaTarget,
          GridScreenShareAloneGraceState.shouldCommitScheduledStop(
            screenShareAloneContext(),
            expectedEpisodeID: target.episodeID,
            expectedPublicationIDs: target.publicationIDs
          )
    else { return }

    log.debug(
      "GRID_TRACE phase=alone_auto_stop_screen_share room=\(target.mediaTarget.roomID)"
    )
    mediaCoordinator.stopScreenSharing()
    resetScreenShareAloneGrace()
  }

  private func cancelScreenShareAloneTask() {
    screenShareAloneTask?.cancel()
    screenShareAloneTask = nil
    screenShareAloneTarget = nil
  }

  private func resetScreenShareAloneGrace() {
    cancelScreenShareAloneTask()
    screenShareAloneGrace.reset()
  }

  private func optimisticallyUpdateRoom(
    roomID: Int64,
    field: GridOptimisticState.RoomField,
    update: (inout GridRoom) -> Void
  ) -> OptimisticRoomMutation? {
    guard let change = GridOptimisticState.updatingRoom(
      in: grids,
      roomID: roomID,
      update: update
    ) else { return nil }

    guard change.fields == Set([field]) else { return nil }
    let key = OptimisticRoomMutationKey(roomID: roomID, field: field)
    let revision = (roomMutationRevisions[key] ?? 0) + 1
    roomMutationRevisions[key] = revision
    grids[change.spaceID] = change.nextGrid
    let mutation = OptimisticRoomMutation(
      key: key,
      revision: revision,
      accessRevision: spaceAccessRevisions[change.spaceID, default: 0],
      change: change
    )
    pendingRoomMutations[key] = mutation
    return mutation
  }

  private func rollbackRoomMutation(_ mutation: OptimisticRoomMutation) {
    guard isCurrent(mutation) else { return }
    pendingRoomMutations.removeValue(forKey: mutation.key)
    guard let currentGrid = grids[mutation.change.spaceID] else { return }
    grids[mutation.change.spaceID] = GridOptimisticState.rollingBackRoomIntent(
      mutation.change,
      in: currentGrid
    )
  }

  private func isCurrent(_ mutation: OptimisticRoomMutation) -> Bool {
    roomMutationRevisions[mutation.key] == mutation.revision
      && spaceAccessRevisions[mutation.change.spaceID, default: 0] == mutation.accessRevision
  }

  private func optimisticallyJoin(roomID: Int64) -> OptimisticMembershipMutation? {
    let fallbackAvatar = makeCurrentUserAvatar()
    let joinedAt = Int64(Date().timeIntervalSince1970)
    guard let change = GridOptimisticState.joining(
      roomID: roomID,
      in: grids,
      avatar: fallbackAvatar,
      microphoneEnabled: mediaCoordinator.isMicrophoneEnabled,
      joinedAt: joinedAt
    ) else { return nil }

    membershipRollbackBaseline.beginIfNeeded(with: change.previousGrids)

    membershipMutationRevision &+= 1
    let mutation = OptimisticMembershipMutation(
      roomID: roomID,
      spaceID: change.spaceID,
      revision: membershipMutationRevision,
      previousGrids: change.previousGrids,
      intent: .join(fallbackAvatar: fallbackAvatar, joinedAt: joinedAt)
    )
    for (spaceID, grid) in change.nextGrids {
      grids[spaceID] = grid
    }
    reconcileAvatarStateOwnership()
    log.debug("GRID_TRACE phase=join_optimistic_applied room=\(roomID) revision=\(mutation.revision)")
    return mutation
  }

  private func optimisticallyLeave(spaceID: Int64) -> OptimisticMembershipMutation? {
    guard let change = GridOptimisticState.leaving(spaceID: spaceID, in: grids) else {
      return nil
    }

    membershipRollbackBaseline.beginIfNeeded(with: change.previousGrids)

    membershipMutationRevision &+= 1
    let mutation = OptimisticMembershipMutation(
      roomID: change.roomID,
      spaceID: spaceID,
      revision: membershipMutationRevision,
      previousGrids: change.previousGrids,
      intent: .leave
    )
    for (changedSpaceID, grid) in change.nextGrids {
      grids[changedSpaceID] = grid
    }
    reconcileAvatarStateOwnership()
    log.debug("GRID_TRACE phase=leave_optimistic_applied room=\(change.roomID) revision=\(mutation.revision)")
    return mutation
  }

  private func rollbackMembershipMutation(_ mutation: OptimisticMembershipMutation) {
    guard membershipMutationRevision == mutation.revision else { return }
    grids = GridOptimisticState.rollingBackMembershipIntent(
      .init(
        roomID: mutation.roomID,
        spaceID: mutation.spaceID,
        previousGrids: membershipRollbackBaseline.grids ?? mutation.previousGrids,
        nextGrids: [:]
      ),
      in: grids
    )
    reconcileAvatarStateOwnership()
    reconcileMediaDemand()
  }

  private func makeCurrentUserAvatar() -> GridAvatar? {
    guard let userID = auth.userId() else { return nil }

    var protocolUser = InlineProtocol.User()
    protocolUser.id = userID
    if let user = ObjectCache.shared.getUser(id: userID)?.user {
      if let firstName = user.firstName {
        protocolUser.firstName = firstName
      }
      if let lastName = user.lastName {
        protocolUser.lastName = lastName
      }
      if let username = user.username {
        protocolUser.username = username
      }
      if let profileCdnURL = user.profileCdnUrl {
        protocolUser.profilePhoto = .with {
          $0.cdnURL = profileCdnURL
          if let uniqueID = user.profileFileUniqueId {
            $0.fileUniqueID = uniqueID
          }
        }
      }
    }

    return .with {
      $0.user = protocolUser
      $0.joinedAt = Int64(Date().timeIntervalSince1970)
      $0.ownedByCurrentSession = true
      $0.microphoneEnabled = mediaCoordinator.isMicrophoneEnabled
    }
  }

  private func applyEnabled(_ enabled: Bool, spaceID: Int64) {
    if enabled {
      enabledSpaceIDs.insert(spaceID)
    } else {
      enabledSpaceIDs.remove(spaceID)
      grids[spaceID] = .with { $0.spaceID = spaceID
        $0.enabled = false
      }
      if acceptedOwnedRoom?.spaceID == spaceID {
        acceptedOwnedRoom = nil
      }
      if localAdmission?.spaceID == spaceID {
        clearLocalAdmission()
      }
      if currentCall?.spaceID == spaceID {
        currentCall = nil
      }
      reconcileAvatarStateOwnership()
    }
  }

  func handle(_ event: GridRoomLifecycleEvent) async {
    switch event {
      case let .grid(event):
        await handle(event)
      case let .realtimeConnection(state):
        await handleConnectionState(state)
      case let .network(snapshot):
        await handleNetworkPath(snapshot)
      case .heartbeat:
        await refreshOwnedPresence()
    }
  }

  private func handle(_ event: GridMediaCoordinatorEvent) async {
    switch event {
      case let .credentialsNeeded(target):
        guard let grid = grids[target.spaceID] else { return }
        await prepareConnectionIfNeeded(grid: grid)
      case let .connected(_, rtcConnectMilliseconds):
        guard let startedAt = mediaInteractionStartedAt else { return }
        mediaInteractionStartedAt = nil
        let totalMilliseconds = Self.elapsedMilliseconds(since: startedAt)
        PerformanceTrace.breadcrumb(
          "Grid connection ready",
          category: "Grid.Connection",
          level: totalMilliseconds >= 3_000 ? .warning : .info,
          data: [
            "click_to_connected_ms": totalMilliseconds,
            "rtc_connect_ms": rtcConnectMilliseconds ?? -1,
          ]
        )
        log.debug(
          "GRID_TRACE phase=click_to_connected elapsed_ms=\(totalMilliseconds) rtc_ms=\(rtcConnectMilliseconds ?? -1)"
        )
      case .microphoneSafetyPaused:
        if let grid = grids.values.first(where: { $0.hasCurrentRoomID }) {
          syncMicrophoneStateIfNeeded(grid: grid)
        }
        reconcileMediaDemand()
      case let .audioEligibilityChanged(eligible):
        publishMediaRetention(eligible && hasLocalAdmission)
      case .screenShareContextChanged:
        reconcileScreenSharePresentationEdges()
        reconcileScreenShareAloneGrace()
    }
  }

  func handle(_ event: GridMembershipSyncEvent) async {
    let operation: GridMembershipOperation = switch event {
      case let .created(value, _), let .joined(value, _), let .moved(value, _),
           let .left(value, _), let .failed(value, _):
        value
    }
    // A reply can already be buffered when auth resets its executor. Implicit replacement
    // may preserve the account token, so an auth-only revision fence must precede all edits.
    guard operation.revision > retiredMembershipRevision,
          (try? auth.validateAccountMutation(operation.accountToken)) != nil
    else { return }
    // Reads concurrent with the claim may linearize before its transaction.
    // Their self projection must not be relabeled as a later ownership fact.
    selfReadEpoch &+= 1
    let mutation = pendingMembershipMutations.removeValue(forKey: operation.revision)
    let accessCurrent = operation.accessRevision == spaceAccessRevisions[operation.spaceID, default: 0]
    let intentCurrent = operation.intentRevision == localIntentRevision
    let wasCancelled = cancelPendingMembershipClaim || !intentCurrent
    // The sole executor is done. A cancellation may enqueue one fenced cleanup
    // only after this outcome identifies the claim that actually committed.
    membershipMutationInFlight = false
    cancelPendingMembershipClaim = false

    // A membership response can have committed before access was revoked.
    // Its complete snapshot cannot restore that space after the revocation.
    // Repair global call display through a fresh, fenced Home read instead.
    guard accessCurrent else {
      if pendingMembershipMutations.isEmpty {
        membershipRollbackBaseline.clear()
      }
      await loadHome()
      return
    }

    switch event {
      case let .created(_, response), let .joined(_, response), let .moved(_, response):
        mediaCoordinator.commitAutomaticMicrophoneChange(operation.automaticMicrophoneChange)
        updateMembershipRollbackBaseline(with: response.grids)
        applySnapshot(response.grids)
        if accessCurrent, intentCurrent, !wasCancelled, response.moved,
           let admission = admission(from: response.currentCall, operation: operation, grids: response.grids)
        {
          currentCall = response.currentCall
          localAdmission = admission
          reconcileAvatarStateOwnership()
          reconcileMediaDemand()
          response.grids.forEach(syncMicrophoneStateIfNeeded)
          if let credentials = response.credentials {
            await accept(credentials)
          }
          if let grid = grids[admission.spaceID] {
            await prepareConnectionIfNeeded(grid: grid)
          }
        } else {
          clearLocalAdmission()
        }
        if wasCancelled, accessCurrent, response.moved,
           let claim = admission(from: response.currentCall, operation: operation, grids: response.grids)
        {
          let call = response.currentCall ?? GridCurrentCall.with {
            $0.callID = claim.callID
            $0.membershipID = claim.membershipID
            $0.spaceID = claim.spaceID
            $0.roomID = claim.roomID
            $0.ownedByCurrentSession = true
          }
          submitCancelledClaimCleanup(call, accountToken: operation.accountToken)
        } else {
          await loadHome()
        }
      case let .left(_, response):
        updateMembershipRollbackBaseline(with: response.grids)
        applySnapshot(response.grids)
        clearLocalAdmission()
        await loadHome()
      case let .failed(_, message):
        mediaInteractionStartedAt = nil
        if intentCurrent, let mutation {
          rollbackMembershipMutation(mutation)
        }
        // A failed leave or uncertain claim can restore display membership, but
        // never restore local permission/capture/admission.
        clearLocalAdmission()
        mediaCoordinator.restoreAutomaticMicrophoneChangeIfCurrent(operation.automaticMicrophoneChange)
        lastError = message
        await loadHome()
        if accessCurrent {
          try? await reloadGrid(spaceID: operation.spaceID)
        }
    }
    if pendingMembershipMutations.isEmpty {
      membershipRollbackBaseline.clear()
    }
  }

  private func submitCancelledClaimCleanup(_ call: GridCurrentCall, accountToken: AuthAccountMutationToken) {
    membershipMutationRevision &+= 1
    membershipMutationInFlight = true
    membershipSync.submit(GridMembershipOperation(
      kind: .leave(roomID: call.roomID),
      spaceID: call.spaceID,
      expectedMembershipID: call.membershipID,
      intentRevision: localIntentRevision,
      accountToken: accountToken,
      microphoneEnabled: false,
      automaticMicrophoneChange: nil,
      accessRevision: spaceAccessRevisions[call.spaceID, default: 0],
      revision: membershipMutationRevision,
      startedAt: Date()
    ))
  }

  func handle(_ event: GridEvent) async {
    switch event.event {
      case let .changed(changed):
        selfReadEpoch &+= 1
        if let target = aloneAutoMuteTarget,
           changed.spaceIds.contains(target.spaceID)
           || (changed.hasRoomID && changed.roomID == target.roomID)
        {
          cancelAloneAutoMute()
        }
        log.debug(
          "GRID_TRACE phase=changed_event_received spaces=\(changed.spaceIds.map { String($0) }.joined(separator: ",")) room=\(changed.hasRoomID ? String(changed.roomID) : "none")"
        )
        for spaceID in changed.spaceIds {
          if enabledSpaceIDs.contains(spaceID) {
            try? await reloadGrid(spaceID: spaceID)
          } else {
            // A Grid-changed event is also the cross-session enablement signal.
            // Refresh settings when this process still believes Grid is disabled.
            await load(spaceID: spaceID)
          }
        }
        await loadHome()
      case let .connectionReady(ready):
        guard ready.hasCredentials else { return }
        log.debug(
          "GRID_TRACE phase=ready_event_received room=\(ready.credentials.connection.roomID) generation=\(ready.credentials.connection.generation)"
        )
        await accept(ready.credentials)
      case let .avatarStateChanged(changed):
        log.debug(
          "GRID_TRACE phase=avatar_state_event_received room=\(changed.roomID) user=\(changed.userID) microphone=\(changed.microphoneEnabled) revision=\(changed.microphoneRevision)"
        )
        applyRemoteAvatarMicrophoneState(
          spaceID: changed.spaceID,
          roomID: changed.roomID,
          userID: changed.userID,
          enabled: changed.microphoneEnabled,
          membershipID: changed.membershipID,
          revision: changed.microphoneRevision
        )
      case let .accessRevoked(revoked):
        selfReadEpoch &+= 1
        clearLocalGrid(spaceID: revoked.spaceID, reason: "server_revoked")
      case nil:
        break
    }
  }

  private func clearLocalGrid(spaceID: Int64, reason: String) {
    if acceptedOwnedRoom?.spaceID == spaceID {
      acceptedOwnedRoom = nil
    }
    if currentCall?.spaceID == spaceID {
      currentCall = nil
    }
    if localAdmission?.spaceID == spaceID {
      clearLocalAdmission()
    }
    let hadMediaDemand = currentMediaTarget()?.spaceID == spaceID
    spaceAccessRevisions[spaceID, default: 0] &+= 1
    homeLoadRevision &+= 1
    pendingMembershipMutations = pendingMembershipMutations.filter { _, mutation in
      mutation.spaceID != spaceID
    }
    membershipRollbackBaseline.remove(spaceID: spaceID)
    if pendingMembershipMutations.isEmpty {
      membershipRollbackBaseline.clear()
    }
    roomMutationRevisions = roomMutationRevisions.filter { key, _ in
      grids[spaceID]?.rooms.contains(where: { $0.id == key.roomID }) != true
    }
    pendingRoomMutations = pendingRoomMutations.filter { _, mutation in
      mutation.change.spaceID != spaceID
    }
    grids.removeValue(forKey: spaceID)
    enabledSpaceIDs.remove(spaceID)
    homeSpaces.removeAll { $0.spaceID == spaceID }
    pendingReloadSpaceIDs.remove(spaceID)
    pendingConnectionSpaceIDs.remove(spaceID)
    failedLoadSpaceIDs.remove(spaceID)
    reconcileAvatarStateOwnership()

    if hadMediaDemand {
      pendingCredentialTarget = nil
      resetCredentialRetry()
      mediaInteractionStartedAt = nil
      mediaCoordinator.clearCredentials()
    }
    reconcileMediaDemand()
    log.info("GRID_TRACE phase=local_grid_cleared space=\(spaceID) reason=\(reason)")
    PerformanceTrace.breadcrumb(
      "Local Grid access cleared",
      category: "Grid.Access",
      level: .info,
      data: ["space_id": spaceID, "reason": reason]
    )
  }

  private func prepareConnectionIfNeeded(grid: InlineProtocol.Grid) async {
    guard let target = currentMediaTarget(), target.spaceID == grid.spaceID,
          let room = grid.rooms.first(where: { $0.id == target.roomID }),
          let admission = localAdmission
    else {
      reconcileMediaDemand()
      return
    }
    reconcileMediaDemand()
    // A LiveKit token is only admission material. Once this exact generation
    // has an established transport, refreshing an expired token on every
    // presence heartbeat adds server work without helping the active room.
    // A later disconnect clears this state; the RTC engine then requests fresh
    // credentials before its next connection attempt.
    if mediaCoordinator.isConnected(to: target) {
      resetCredentialRetry()
      return
    }
    if mediaCoordinator.hasUsableCredentials(for: target) {
      resetCredentialRetry()
      return
    }
    mediaCoordinator.invalidateCredentials(for: target)
    guard pendingCredentialTarget != target else { return }

    pendingCredentialTarget = target
    defer {
      if pendingCredentialTarget == target {
        pendingCredentialTarget = nil
      }
    }
    let startedAt = Date()
    log.debug(
      "GRID_ENGINE phase=credentials_fetch_start room=\(room.id) generation=\(room.connection.generation)"
    )
    do {
      guard let connection = try await api.prepareConnection(
        roomID: room.id,
        generation: room.connection.generation,
        expectedMembershipID: target.membershipID,
        accountToken: admission.accountToken
      ) else {
        log.debug(
          "GRID_ENGINE phase=credentials_fetch_unavailable room=\(room.id) generation=\(room.connection.generation) elapsed_ms=\(Self.elapsedMilliseconds(since: startedAt))"
        )
        scheduleCredentialRetry(for: target)
        return
      }
      log.debug(
        "GRID_ENGINE phase=credentials_fetch_done room=\(room.id) generation=\(room.connection.generation) elapsed_ms=\(Self.elapsedMilliseconds(since: startedAt))"
      )
      await accept(connection)
    } catch {
      guard currentMediaTarget() == target,
            (try? auth.validateAccountMutation(admission.accountToken)) != nil
      else { return }
      lastError = String(describing: error)
      log.error(
        "GRID_ENGINE phase=credentials_fetch_failed room=\(room.id) generation=\(room.connection.generation)",
        error: error
      )
      scheduleCredentialRetry(for: target)
    }
  }

  private func accept(_ credentials: GridConnectionCredentials) async {
    guard let serverURL = URL(string: credentials.serverURL),
          let target = currentMediaTarget(),
          let admission = localAdmission,
          GridCredentialBinding.accepts(
            credentials: credentials, target: target,
            userID: admission.accountToken.userID,
            callTransferEnabled: callTransferEnabled
          )
    else {
      log.debug(
        "GRID_ENGINE phase=credentials_ignored_stale room=\(credentials.connection.roomID) generation=\(credentials.connection.generation)"
      )
      return
    }
    let accepted = mediaCoordinator.accept(InlineRTCCredentials(
      target: target.rtcSessionID,
      serverURL: serverURL,
      participantIdentity: credentials.participantIdentity,
      token: credentials.token,
      expiresAt: Date(timeIntervalSince1970: TimeInterval(credentials.expiresAt))
    ))
    guard accepted else { return }
    resetCredentialRetry()
    log.debug(
      "GRID_ENGINE phase=credentials_accepted room=\(target.roomID) generation=\(target.generation)"
    )
  }

  private func scheduleCredentialRetry(for target: GridMediaTarget) {
    guard currentMediaTarget() == target,
          credentialRetryTask == nil
    else { return }
    if credentialRetryTarget != target {
      credentialRetryTarget = target
      credentialRetryAttempt = 0
    }
    credentialRetryAttempt &+= 1
    let attempt = credentialRetryAttempt
    let delay = Self.credentialRetryDelay(attempt: attempt)
    log.debug(
      "GRID_ENGINE phase=credentials_retry_scheduled room=\(target.roomID) generation=\(target.generation) attempt=\(attempt) delay_s=\(delay)"
    )
    credentialRetryTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(delay))
      guard !Task.isCancelled else { return }
      await self?.credentialRetryFired(target: target, attempt: attempt)
    }
  }

  private func credentialRetryFired(target: GridMediaTarget, attempt: Int) async {
    guard credentialRetryTarget == target,
          credentialRetryAttempt == attempt
    else { return }
    credentialRetryTask = nil
    guard currentMediaTarget() == target,
          let grid = grids[target.spaceID]
    else {
      resetCredentialRetry()
      return
    }
    await prepareConnectionIfNeeded(grid: grid)
  }

  private func resetCredentialRetry() {
    credentialRetryTask?.cancel()
    credentialRetryTask = nil
    credentialRetryTarget = nil
    credentialRetryAttempt = 0
  }

  private func refreshOwnedPresence() async {
    guard let admission = localAdmission else { return }
    try? await reloadGrid(spaceID: admission.spaceID, renewingMembershipID: admission.membershipID)
  }

  private func syncMicrophoneStateIfNeeded(grid: InlineProtocol.Grid) {
    guard let admission = localAdmission, admission.spaceID == grid.spaceID, grid.hasCurrentRoomID,
          let room = grid.rooms.first(where: { $0.id == grid.currentRoomID }),
          let avatar = room.avatars.first(where: \.ownedByCurrentSession),
          avatar.membershipID == admission.membershipID
    else { return }
    let microphoneEnabled = mediaCoordinator.isMicrophoneEnabled
    guard avatar.microphoneEnabled != microphoneEnabled else { return }
    applyAvatarMicrophoneState(
      spaceID: grid.spaceID,
      roomID: room.id,
      userID: nil,
      enabled: microphoneEnabled
    )
    avatarStateSync.submitMicrophoneState(roomID: room.id, enabled: microphoneEnabled)
  }

  private func applyAvatarMicrophoneState(
    spaceID: Int64,
    roomID: Int64,
    userID: Int64?,
    enabled: Bool,
    revision: Int32? = nil
  ) {
    guard var grid = grids[spaceID],
          let roomIndex = grid.rooms.firstIndex(where: { $0.id == roomID }),
          let avatarIndex = grid.rooms[roomIndex].avatars.firstIndex(where: { avatar in
            if let userID {
              return avatar.user.id == userID
            }
            return avatar.ownedByCurrentSession
          })
    else { return }
    grid.rooms[roomIndex].avatars[avatarIndex].microphoneEnabled = enabled
    if let revision {
      grid.rooms[roomIndex].avatars[avatarIndex].microphoneRevision = revision
    }
    grids[spaceID] = grid
  }

  /// Inline's local microphone intent remains authoritative for the avatar
  /// owned by this process. A delayed echo from an earlier rapid toggle must
  /// not repaint that avatar with stale server state; other avatars always use
  /// the transient state sent by their owning session.
  private func applyRemoteAvatarMicrophoneState(
    spaceID: Int64,
    roomID: Int64,
    userID: Int64,
    enabled: Bool,
    membershipID: String,
    revision: Int32
  ) {
    guard let grid = grids[spaceID],
          let room = grid.rooms.first(where: { $0.id == roomID }),
          let avatar = room.avatars.first(where: { $0.user.id == userID }),
          avatar.membershipID == membershipID,
          revision >= avatar.microphoneRevision
    else { return }
    applyAvatarMicrophoneState(
      spaceID: spaceID,
      roomID: roomID,
      userID: userID,
      enabled: avatar.ownedByCurrentSession ? mediaCoordinator.isMicrophoneEnabled : enabled,
      revision: revision
    )
  }

  private func handleConnectionState(_ state: RealtimeConnectionState) async {
    let previousState = lastRealtimeConnectionState
    lastRealtimeConnectionState = state
    switch state {
      case .connecting:
        // Inline realtime and LiveKit have independent transports. Keep media
        // alive while the app server reconnects; LiveKit handles its own recovery.
        break
      case .connected, .updating:
        if previousState == nil || previousState == .connecting {
          selfReadEpoch &+= 1
          networkRefreshRevision &+= 1
          avatarStateSync.retryLatestFailure()
          mediaCoordinator.networkBecameAvailable()
          await loadHome()
          await retryPendingConnectionLoads()
          await refreshOwnedPresence()
        }
    }
  }

  private var realtimeReady: Bool {
    switch lastRealtimeConnectionState {
      case .connected, .updating:
        true
      case .connecting, nil:
        false
    }
  }

  private func handleNetworkPath(_ snapshot: GridNetworkPathSnapshot) async {
    let previousSnapshot = lastNetworkPathSnapshot
    lastNetworkPathSnapshot = snapshot
    networkAvailable = snapshot.available
    log.debug(
      "GRID_TRACE phase=network_path_changed available=\(snapshot.available) interface=\(snapshot.interfaceDescription) constrained=\(snapshot.constrained) expensive=\(snapshot.expensive)"
    )
    if previousSnapshot == nil {
      return
    }
    if snapshot.available {
      networkRefreshRevision &+= 1
      avatarStateSync.retryLatestFailure()
      mediaCoordinator.networkBecameAvailable()
      await loadHome()
      await retryPendingConnectionLoads()
      await refreshOwnedPresence()
    }
  }

  private func retryPendingConnectionLoads() async {
    let deferredSpaceIDs = pendingConnectionSpaceIDs.sorted()
    pendingConnectionSpaceIDs.removeAll()
    for spaceID in deferredSpaceIDs {
      await load(spaceID: spaceID)
    }
  }

  public func applicationDidWake() async {
    avatarStateSync.retryLatestFailure()
    mediaCoordinator.applicationDidWake()
    await loadHome()
    await refreshOwnedPresence()
  }

  private func reconcileAvatarStateOwnership() {
    guard let admission = localAdmission else {
      avatarStateSync.setOwnedRoom(nil)
      return
    }
    avatarStateSync.setOwnedRoom(
      admission.roomID,
      membershipID: admission.membershipID,
      accountToken: admission.accountToken
    )
  }

  private func currentMediaTarget() -> GridMediaTarget? {
    guard let admission = localAdmission,
          (try? auth.validateAccountMutation(admission.accountToken)) != nil,
          acceptedOwnedRoom?.spaceID == admission.spaceID,
          acceptedOwnedRoom?.roomID == admission.roomID,
          acceptedOwnedRoom?.membershipID == admission.membershipID,
          let grid = grids[admission.spaceID], grid.enabled,
          let room = grid.rooms.first(where: { $0.id == admission.roomID }), room.hasConnection,
          room.avatars.contains(where: { $0.ownedByCurrentSession && $0.membershipID == admission.membershipID })
    else { return nil }
    if callTransferEnabled {
      guard let call = currentCall, call.ownedByCurrentSession,
            call.callID == admission.callID, call.membershipID == admission.membershipID
      else { return nil }
    }
    return GridMediaTarget(
      callID: admission.callID,
      membershipID: admission.membershipID,
      spaceID: admission.spaceID,
      roomID: admission.roomID,
      generation: room.connection.generation
    )
  }

  private func isOwnedUser(_ userID: Int64) -> Bool {
    grids.values.lazy
      .flatMap(\.rooms)
      .flatMap(\.avatars)
      .contains { $0.ownedByCurrentSession && $0.user.id == userID }
  }

  private static func liveKitIdentityPrefix(userID: Int64) -> String {
    "inline-grid-user-\(userID)"
  }

  private static func identity(_ identity: String, matchesUserID userID: Int64) -> Bool {
    let prefix = liveKitIdentityPrefix(userID: userID)
    return identity == prefix || identity.hasPrefix("\(prefix)-")
  }

  private func participantIdentities(for avatar: GridAvatar) -> Set<String> {
    if !avatar.membershipID.isEmpty {
      return [
        "\(Self.liveKitIdentityPrefix(userID: avatar.user.id))-\(avatar.membershipID)",
      ]
    }
    return Set(
      media.connectedParticipantIdentities.filter {
        Self.identity($0, matchesUserID: avatar.user.id)
      }
    )
  }

  private func screenShareParticipantIdentity(for avatar: GridAvatar) -> String? {
    let identities = participantIdentities(for: avatar)
    if let identity = identities.sorted().first(where: {
      media.participantScreenShareIntents[$0] == true
    }) {
      return identity
    }
    if let identity = screenShares(avatar: avatar).first?.participantIdentity {
      return identity
    }
    return identities.sorted().first
  }

  private func openScreenShare(
    user: InlineProtocol.User,
    participantIdentity: String
  ) {
    if let share = screenShares(participantIdentity: participantIdentity).first {
      platformEffects.openScreenShare?(user, share, self)
      return
    }
    guard isScreenShareIntended(participantIdentity: participantIdentity) else { return }

    pendingScreenShareOpenTasks.removeValue(forKey: participantIdentity)?.task.cancel()
    let requestID = UUID()
    let task = Task { [weak self] in
      for _ in 0 ..< 80 {
        guard !Task.isCancelled, let self else { return }
        if let share = screenShares(participantIdentity: participantIdentity).first {
          finishPendingScreenShareOpen(
            requestID: requestID,
            participantIdentity: participantIdentity
          )
          platformEffects.openScreenShare?(user, share, self)
          return
        }
        guard isScreenShareIntended(participantIdentity: participantIdentity) else {
          finishPendingScreenShareOpen(
            requestID: requestID,
            participantIdentity: participantIdentity
          )
          return
        }
        try? await Task.sleep(for: .milliseconds(100))
      }
      guard !Task.isCancelled, let self else { return }
      finishPendingScreenShareOpen(
        requestID: requestID,
        participantIdentity: participantIdentity
      )
      if isScreenShareIntended(participantIdentity: participantIdentity) {
        platformEffects.showError?("The shared screen hasn’t arrived yet")
      }
    }
    pendingScreenShareOpenTasks[participantIdentity] = GridPendingScreenShareOpen(
      id: requestID,
      task: task
    )
  }

  private func finishPendingScreenShareOpen(
    requestID: UUID,
    participantIdentity: String
  ) {
    guard pendingScreenShareOpenTasks[participantIdentity]?.id == requestID else { return }
    pendingScreenShareOpenTasks[participantIdentity] = nil
  }

  public func setInputSelection(_ selection: AudioInputSelection) {
    mediaCoordinator.setInput(selection)
  }

  public func setOutputSelection(_ selection: AudioOutputSelection) {
    mediaCoordinator.setOutput(selection)
  }

  public func setOutputVolume(_ volume: Float) {
    mediaCoordinator.setOutputVolume(volume)
  }

  public func refreshInputDevices() {
    mediaCoordinator.refreshInputDevices()
  }

  public func refreshOutputDevices() {
    mediaCoordinator.refreshOutputDevices()
  }

  public func retryAudio() {
    mediaCoordinator.retryAudio()
  }

  private static func elapsedMilliseconds(since date: Date) -> Int {
    Int(Date().timeIntervalSince(date) * 1_000)
  }

  private static func credentialRetryDelay(attempt: Int) -> Int {
    switch attempt {
      case 1: 1
      case 2: 2
      case 3: 4
      case 4: 8
      case 5: 15
      default: 30
    }
  }

  private func operationRoomID(_ operation: GridMembershipOperation) -> Int64? {
    switch operation.kind {
      case .create: nil
      case let .join(roomID), let .leave(roomID), let .move(_, roomID): roomID
    }
  }

  private func applyPendingMembershipIntent() {
    guard let mutation = pendingMembershipMutations[membershipMutationRevision],
          grids[mutation.spaceID] != nil
    else { return }

    let change: GridOptimisticState.MembershipChange? = switch mutation.intent {
      case let .join(fallbackAvatar, joinedAt):
        GridOptimisticState.joining(
          roomID: mutation.roomID,
          in: grids,
          avatar: fallbackAvatar,
          microphoneEnabled: mediaCoordinator.isMicrophoneEnabled,
          joinedAt: joinedAt
        )
      case .leave:
        GridOptimisticState.leaving(spaceID: mutation.spaceID, in: grids)
    }
    guard let change else { return }
    for (spaceID, grid) in change.nextGrids {
      grids[spaceID] = grid
    }
  }

  private func updateMembershipRollbackBaseline(with snapshots: [InlineProtocol.Grid]) {
    let confirmedSnapshots = snapshots.filter { snapshot in
      let previousRevision = lastAcceptedSnapshotRevisions[snapshot.spaceID]
      if let previousRevision {
        return snapshot.revision >= previousRevision
      }
      return true
    }
    membershipRollbackBaseline.mergeConfirmed(confirmedSnapshots)
  }

  private func beginSelfRead() -> GridSelfReadFence? {
    guard let token = try? auth.beginAccountMutation() else { return nil }
    selfReadSequence &+= 1
    return GridSelfReadFence(epoch: selfReadEpoch, sequence: selfReadSequence, accountToken: token)
  }

  private func isCurrent(_ read: GridSelfReadFence) -> Bool {
    read.epoch == selfReadEpoch
      && (try? auth.validateAccountMutation(read.accountToken)) != nil
  }

  private func applySelfRead(_ call: GridCurrentCall?, capability: Bool, fence: GridSelfReadFence) {
    guard isCurrent(fence), !membershipMutationInFlight,
          fence.sequence >= lastAcceptedSelfReadSequence else { return }
    lastAcceptedSelfReadSequence = fence.sequence
    callTransferEnabled = capability
    currentCall = call
    #if os(iOS)
    if !capability {
      clearLocalAdmission()
    }
    #endif
    reconcileLocalAdmission()
    reconcileAvatarStateOwnership()
    reconcileMediaDemand()
  }

  private func admission(
    from call: GridCurrentCall?,
    operation: GridMembershipOperation,
    grids snapshots: [InlineProtocol.Grid]
  ) -> GridLocalAdmission? {
    if let call, GridCallClaimAdmission.accepts(
      committedCall: call, newestGrid: grids[call.spaceID], acceptedAuthority: acceptedOwnedRoom
    ) {
      return GridLocalAdmission(
        callID: call.callID, membershipID: call.membershipID,
        spaceID: call.spaceID, roomID: call.roomID, accountToken: operation.accountToken
      )
    }
    #if os(macOS)
    // Legacy OFF mode remains usable by explicit Create/Join only. Browsing
    // never creates an admission even if its auth session is still the owner.
    if !callTransferEnabled {
      for grid in snapshots where grid.hasCurrentRoomID {
        if let room = grid.rooms.first(where: { $0.id == grid.currentRoomID }),
           let avatar = room.avatars.first(where: \.ownedByCurrentSession),
           !avatar.membershipID.isEmpty,
           acceptedOwnedRoom?.spaceID == grid.spaceID,
           acceptedOwnedRoom?.roomID == room.id,
           acceptedOwnedRoom?.membershipID == avatar.membershipID,
           self.grids[grid.spaceID]?.rooms.first(where: { $0.id == room.id })?.avatars.contains(where: {
             $0.ownedByCurrentSession && $0.membershipID == avatar.membershipID
           }) == true
        {
          return GridLocalAdmission(
            callID: "", membershipID: avatar.membershipID,
            spaceID: grid.spaceID, roomID: room.id, accountToken: operation.accountToken
          )
        }
      }
    }
    #endif
    return nil
  }

  private func reconcileLocalAdmission() {
    guard let admission = localAdmission else { return }
    let avatarMatches = grids[admission.spaceID]?.rooms.first(where: { $0.id == admission.roomID })?.avatars
      .contains(where: {
        $0.ownedByCurrentSession && $0.membershipID == admission.membershipID
      }) == true
    let callMatches = !callTransferEnabled || (currentCall?.ownedByCurrentSession == true
      && currentCall?.callID == admission.callID && currentCall?.membershipID == admission.membershipID)
    let authorityMatches = acceptedOwnedRoom?.spaceID == admission.spaceID
      && acceptedOwnedRoom?.roomID == admission.roomID
      && acceptedOwnedRoom?.membershipID == admission.membershipID
    if !avatarMatches || !callMatches || !authorityMatches
      || (try? auth.validateAccountMutation(admission.accountToken)) == nil
    {
      clearLocalAdmission()
    }
  }

  private func clearLocalAdmission() {
    publishMediaRetention(false)
    localAdmission = nil
    pendingCredentialTarget = nil
    resetCredentialRetry()
    avatarStateSync.setOwnedRoom(nil)
    mediaCoordinator.clearCredentials()
    mediaCoordinator.setTarget(nil)
    mediaInteractionStartedAt = nil
    resetScreenSharePresentationEdges()
  }

  private func publishMediaRetention(_ eligible: Bool) {
    guard eligible != lastRetainedMediaEligible,
          let accountToken = localAdmission?.accountToken ?? (try? auth.beginAccountMutation())
    else { return }
    lastRetainedMediaEligible = eligible
    pendingRetention = (eligible, accountToken)
    guard retentionTask == nil else { return }
    retentionTask = Task { [weak self] in
      guard let self else { return }
      while !Task.isCancelled, let next = pendingRetention {
        pendingRetention = nil
        await realtime.setGridMediaRetention(eligible: next.eligible, accountToken: next.accountToken)
      }
      retentionTask = nil
    }
  }
}

private struct OptimisticRoomMutationKey: Hashable {
  let roomID: Int64
  let field: GridOptimisticState.RoomField
}

private struct GridAloneAutoMuteTarget: Equatable {
  let spaceID: Int64
  let roomID: Int64
  let userID: Int64
}

private struct GridScreenShareAloneTarget: Equatable {
  let mediaTarget: GridMediaTarget
  let episodeID: UInt64
  let publicationIDs: Set<String>
}

private struct GridScreenShareNotice {
  let target: GridMediaTarget
  let user: InlineProtocol.User
  let participantIdentity: String
}

private struct GridPendingScreenShareOpen {
  let id: UUID
  let task: Task<Void, Never>
}

private struct OptimisticRoomMutation {
  let key: OptimisticRoomMutationKey
  let revision: Int
  let accessRevision: Int
  let change: GridOptimisticState.RoomChange
}

private struct OptimisticMembershipMutation {
  enum Intent {
    case join(fallbackAvatar: GridAvatar?, joinedAt: Int64)
    case leave
  }

  let roomID: Int64
  let spaceID: Int64
  let revision: Int
  let previousGrids: [Int64: InlineProtocol.Grid]
  let intent: Intent
}

private struct GridLocalAdmission {
  let callID: String
  let membershipID: String
  let spaceID: Int64
  let roomID: Int64
  let accountToken: AuthAccountMutationToken
}

private struct GridSelfReadFence {
  let epoch: Int
  let sequence: Int
  let accountToken: AuthAccountMutationToken
}
