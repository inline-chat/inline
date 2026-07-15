import Auth
import Foundation
import InlineKit
import InlineRTC
import InlineProtocol
import Logger
import Observation
import RealtimeV2

@MainActor
@Observable
final class GridRoomService {
  private(set) var grids: [Int64: InlineProtocol.Grid] = [:]
  private(set) var enabledSpaceIDs = Set<Int64>()
  private(set) var homeSpaces: [GridHomeSpace] = []
  private(set) var loadingSpaceIDs = Set<Int64>()
  private(set) var failedLoadSpaceIDs = Set<Int64>()
  private(set) var lastError: String?
  private(set) var networkRefreshRevision = 0
  private(set) var networkAvailable = true
  var connectionRecoveryAttempt: Int { media.recoveryAttempt }
  let media: GridMediaPresentation

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
  @ObservationIgnored private var roomMutationRevisions: [OptimisticRoomMutationKey: Int] = [:]
  @ObservationIgnored private var pendingRoomMutations: [OptimisticRoomMutationKey: OptimisticRoomMutation] = [:]
  @ObservationIgnored private var membershipMutationRevision = 0
  @ObservationIgnored private var pendingMembershipMutations: [Int: OptimisticMembershipMutation] = [:]
  @ObservationIgnored private var membershipRollbackBaseline =
    GridOptimisticState.MembershipRollbackBaseline()
  @ObservationIgnored private var lastAcceptedSnapshotRevisions: [Int64: Int64] = [:]
  @ObservationIgnored private var spaceAccessRevisions: [Int64: Int] = [:]
  @ObservationIgnored private var homeLoadRevision = 0
  @ObservationIgnored private var lastRealtimeConnectionState: RealtimeConnectionState?
  @ObservationIgnored private var pendingCredentialTarget: GridMediaTarget?
  @ObservationIgnored private var credentialRetryTask: Task<Void, Never>?
  @ObservationIgnored private var credentialRetryTarget: GridMediaTarget?
  @ObservationIgnored private var credentialRetryAttempt = 0
  @ObservationIgnored private var mediaInteractionStartedAt: Date?
  @ObservationIgnored private let log = Log.scoped("GridRoomService")

  init(
    realtime: RealtimeV2 = Api.realtime,
    userDefaults: UserDefaults = .standard,
    engine: InlineRTCSession
  ) {
    let api = GridRoomAPI(realtime: realtime)
    self.api = api
    avatarStateSync = GridAvatarStateSync(api: api)
    let membershipSync = GridMembershipSync(api: api)
    self.membershipSync = membershipSync
    let networkMonitor = GridNetworkMonitor()
    lifecycle = GridRoomLifecycle(realtime: realtime, network: networkMonitor)
    let inputPreferences = AudioInputPreferenceStore(
      defaults: userDefaults,
      deviceIDKey: "grid.preferredInputDeviceID",
      deviceNameKey: "grid.preferredInputDeviceName"
    )
    homePreferences = GridHomePreferences(defaults: userDefaults)
    let mediaCoordinator = GridMediaCoordinator(
      engine: engine,
      defaults: userDefaults,
      inputPreferences: inputPreferences
    )
    self.mediaCoordinator = mediaCoordinator
    media = mediaCoordinator.presentation
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

  deinit {
    lifecycleTask?.cancel()
    mediaEventsTask?.cancel()
    membershipEventsTask?.cancel()
    credentialRetryTask?.cancel()
  }

  func isEnabled(spaceID: Int64) -> Bool {
    enabledSpaceIDs.contains(spaceID)
  }

  func prepareForLogout() async {
    let invalidatedSpaceIDs = Set(spaceAccessRevisions.keys)
      .union(grids.keys)
      .union(enabledSpaceIDs)
      .union(loadingSpaceIDs)
      .union(pendingReloadSpaceIDs)
    pendingCredentialTarget = nil
    resetCredentialRetry()
    grids.removeAll()
    homeSpaces.removeAll()
    enabledSpaceIDs.removeAll()
    loadingSpaceIDs.removeAll()
    failedLoadSpaceIDs.removeAll()
    pendingReloadSpaceIDs.removeAll()
    for spaceID in invalidatedSpaceIDs {
      spaceAccessRevisions[spaceID, default: 0] &+= 1
    }
    homeLoadRevision &+= 1
    roomMutationRevisions.removeAll()
    pendingRoomMutations.removeAll()
    membershipMutationRevision &+= 1
    pendingMembershipMutations.removeAll()
    membershipRollbackBaseline.clear()
    lastAcceptedSnapshotRevisions.removeAll()
    membershipSync.reset()
    avatarStateSync.setOwnedRoom(nil)
    await mediaCoordinator.shutdown()
  }

  func grid(spaceID: Int64) -> InlineProtocol.Grid? {
    grids[spaceID]
  }

  func recentAvatars(spaceID: Int64, limit: Int = 4) -> [GridAvatar] {
    guard let grid = grids[spaceID] else { return [] }
    return Array(
      grid.rooms
        .flatMap(\.avatars)
        .sorted { $0.joinedAt > $1.joinedAt }
        .prefix(limit)
    )
  }

  func loadHome() async {
    homeLoadRevision &+= 1
    let revision = homeLoadRevision
    do {
      let nextHomeSpaces = try await api.home()
      guard revision == homeLoadRevision else { return }
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
      lastError = String(describing: error)
      log.warning("GRID_TRACE phase=home_load_failed")
      PerformanceTrace.breadcrumb(
        "Grid Home discovery failed",
        category: "Grid.Home",
        level: .warning
      )
    }
  }

  var orderedHomeSpaces: [GridHomeSpace] {
    homePreferences.ordered(homeSpaces)
  }

  func recordGridOpened(spaceID: Int64) {
    homePreferences.recordOpened(spaceID: spaceID)
  }

  func audioLevel(userID: Int64) -> Float {
    let legacyIdentity = "inline-grid-user-\(userID)"
    return media.participantAudioLevels
      .filter { $0.key == legacyIdentity || $0.key.hasPrefix("\(legacyIdentity)-") }
      .map(\.value)
      .max() ?? 0
  }

  func load(spaceID: Int64) async {
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

  func setEnabled(_ enabled: Bool, spaceID: Int64) async throws {
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

  func createAndJoin(spaceID: Int64) {
    let startedAt = Date()
    mediaCoordinator.requestMicrophonePermission()
    GridSoundEffects.shared.play(.join)
    log.debug("GRID_TRACE phase=create_client_start space=\(spaceID)")
    membershipMutationRevision &+= 1
    membershipSync.submit(GridMembershipOperation(
      kind: .create,
      spaceID: spaceID,
      accessRevision: spaceAccessRevisions[spaceID, default: 0],
      revision: membershipMutationRevision,
      startedAt: startedAt
    ))
  }

  func join(roomID: Int64) {
    let startedAt = Date()
    if let room = grids.values.lazy.flatMap(\.rooms).first(where: { $0.id == roomID }),
       room.avatars.isEmpty == false {
      mediaInteractionStartedAt = startedAt
    } else {
      mediaInteractionStartedAt = nil
    }
    GridSoundEffects.shared.play(.join)
    log.debug("GRID_TRACE phase=join_client_start room=\(roomID)")
    guard let mutation = optimisticallyJoin(roomID: roomID) else { return }
    mediaCoordinator.requestMicrophonePermission()
    reconcileMediaDemand()

    pendingMembershipMutations[mutation.revision] = mutation
    membershipSync.submit(GridMembershipOperation(
      kind: .join(roomID: roomID),
      spaceID: mutation.spaceID,
      accessRevision: spaceAccessRevisions[mutation.spaceID, default: 0],
      revision: mutation.revision,
      startedAt: startedAt
    ))
  }

  func leaveCurrentRoom(spaceID: Int64) {
    guard let mutation = optimisticallyLeave(spaceID: spaceID) else { return }
    GridSoundEffects.shared.play(.leave)
    mediaCoordinator.clearCredentials()
    mediaInteractionStartedAt = nil
    pendingCredentialTarget = nil
    reconcileMediaDemand()

    pendingMembershipMutations[mutation.revision] = mutation
    membershipSync.submit(GridMembershipOperation(
      kind: .leave(roomID: mutation.roomID),
      spaceID: spaceID,
      accessRevision: spaceAccessRevisions[spaceID, default: 0],
      revision: mutation.revision,
      startedAt: Date()
    ))
  }

  func toggleMicrophone(spaceID: Int64) {
    guard let grid = grids[spaceID], grid.hasCurrentRoomID,
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

  func toggleCurrentMicrophone() {
    guard let grid = grids.values.first(where: { grid in
      guard grid.hasCurrentRoomID,
            let room = grid.rooms.first(where: { $0.id == grid.currentRoomID })
      else { return false }
      return room.avatars.contains(where: \.ownedByCurrentSession)
    }) else { return }

    toggleMicrophone(spaceID: grid.spaceID)
  }

  func toggleRoomLock(roomID: Int64, locked: Bool) async {
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
      if networkAvailable { try? await reloadGrid(spaceID: mutation.change.spaceID) }
    }
  }

  func setRoomTitle(roomID: Int64, title: String) async {
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
      if networkAvailable { try? await reloadGrid(spaceID: mutation.change.spaceID) }
    }
  }

  func deleteRoom(roomID: Int64) async {
    guard let spaceID = grids.first(where: { _, grid in
      grid.rooms.contains(where: { $0.id == roomID })
    })?.key else { return }
    let accessRevision = spaceAccessRevisions[spaceID, default: 0]
    do {
      let grid = try await api.deleteRoom(roomID: roomID)
      guard accessRevision == spaceAccessRevisions[spaceID, default: 0] else { return }
      applySnapshot([grid])
    } catch {
      lastError = String(describing: error)
    }
  }

  private func reloadGrid(spaceID: Int64) async throws {
    let accessRevision = spaceAccessRevisions[spaceID, default: 0]
    let grid = try await api.grid(spaceID: spaceID)
    guard accessRevision == spaceAccessRevisions[spaceID, default: 0] else { return }
    applySnapshot([grid])
    syncMicrophoneStateIfNeeded(grid: grid)
    await prepareConnectionIfNeeded(grid: grid)
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
      var grid = incomingGrid
      for mutation in pendingRoomMutations.values where mutation.change.spaceID == grid.spaceID {
        grid = GridOptimisticState.applyingRoomIntent(mutation.change, to: grid)
      }
      grids[grid.spaceID] = grid
      failedLoadSpaceIDs.remove(grid.spaceID)
      applyEnabled(grid.enabled, spaceID: grid.spaceID)
    }
    applyPendingMembershipIntent()

    reconcileAvatarStateOwnership()
    reconcileMediaDemand()
  }

  private func reconcileMediaDemand() {
    let target = currentMediaTarget()
    if credentialRetryTarget != target { resetCredentialRetry() }
    mediaCoordinator.setTarget(target)
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
    for (spaceID, grid) in change.nextGrids { grids[spaceID] = grid }
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
    for (changedSpaceID, grid) in change.nextGrids { grids[changedSpaceID] = grid }
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
    guard let userID = Auth.shared.getCurrentUserId() else { return nil }

    var protocolUser = InlineProtocol.User()
    protocolUser.id = userID
    if let user = ObjectCache.shared.getUser(id: userID)?.user {
      if let firstName = user.firstName { protocolUser.firstName = firstName }
      if let lastName = user.lastName { protocolUser.lastName = lastName }
      if let username = user.username { protocolUser.username = username }
      if let profileCdnURL = user.profileCdnUrl {
        protocolUser.profilePhoto = .with {
          $0.cdnURL = profileCdnURL
          if let uniqueID = user.profileFileUniqueId { $0.fileUniqueID = uniqueID }
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
      grids[spaceID] = .with { $0.spaceID = spaceID; $0.enabled = false }
      reconcileAvatarStateOwnership()
    }
  }

  private func handle(_ event: GridRoomLifecycleEvent) async {
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
    }
  }

  private func handle(_ event: GridMembershipSyncEvent) async {
    let operation: GridMembershipOperation
    switch event {
    case let .created(value, _), let .joined(value, _), let .left(value, _), let .failed(value, _):
      operation = value
    }

    let mutation = pendingMembershipMutations.removeValue(forKey: operation.revision)
    guard operation.accessRevision == spaceAccessRevisions[operation.spaceID, default: 0] else {
      return
    }
    let isLatestIntent = operation.revision == membershipMutationRevision

    switch event {
    case let .created(_, response):
      updateMembershipRollbackBaseline(with: response.grids)
      await apply(
        grids: response.grids,
        credentials: isLatestIntent ? response.credentials : nil
      )
      log.debug(
        "GRID_TRACE phase=create_client_done space=\(operation.spaceID) elapsed_ms=\(Self.elapsedMilliseconds(since: operation.startedAt))"
      )
    case let .joined(_, response):
      updateMembershipRollbackBaseline(with: response.grids)
      await apply(
        grids: response.grids,
        credentials: isLatestIntent ? response.credentials : nil
      )
      log.debug(
        "GRID_TRACE phase=join_client_done room=\(operationRoomID(operation) ?? 0) elapsed_ms=\(Self.elapsedMilliseconds(since: operation.startedAt))"
      )
    case let .left(_, nextGrids):
      updateMembershipRollbackBaseline(with: nextGrids)
      applySnapshot(nextGrids)
    case let .failed(_, message):
      mediaInteractionStartedAt = nil
      if isLatestIntent, let mutation {
        rollbackMembershipMutation(mutation)
        if case .leave = operation.kind, let restoredGrid = grids[operation.spaceID] {
          await prepareConnectionIfNeeded(grid: restoredGrid)
        }
      }
      lastError = message
      log.warning(
        "GRID_TRACE phase=membership_client_failed revision=\(operation.revision) elapsed_ms=\(Self.elapsedMilliseconds(since: operation.startedAt))"
      )
    }
    if pendingMembershipMutations.isEmpty {
      membershipRollbackBaseline.clear()
    }
  }

  private func handle(_ event: GridEvent) async {
    switch event.event {
    case let .changed(changed):
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
      clearLocalGrid(spaceID: revoked.spaceID, reason: "server_revoked")
    case nil:
      break
    }
  }

  private func clearLocalGrid(spaceID: Int64, reason: String) {
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
    guard grid.hasCurrentRoomID,
          let room = grid.rooms.first(where: { $0.id == grid.currentRoomID }),
          room.hasConnection,
          room.avatars.contains(where: \.ownedByCurrentSession)
    else {
      reconcileMediaDemand()
      return
    }
    let target = GridMediaTarget(
      spaceID: grid.spaceID,
      roomID: room.id,
      generation: room.connection.generation
    )
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
        generation: room.connection.generation
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
      lastError = String(describing: error)
      log.error(
        "GRID_ENGINE phase=credentials_fetch_failed room=\(room.id) generation=\(room.connection.generation)",
        error: error
      )
      scheduleCredentialRetry(for: target)
    }
  }

  private func accept(_ credentials: GridConnectionCredentials) async {
    guard credentials.hasConnection,
          let serverURL = URL(string: credentials.serverURL),
          let target = currentMediaTarget(),
          target.roomID == credentials.connection.roomID,
          target.generation == credentials.connection.generation
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
    for grid in grids.values where grid.hasCurrentRoomID {
      try? await reloadGrid(spaceID: grid.spaceID)
      return
    }
  }

  private func syncMicrophoneStateIfNeeded(grid: InlineProtocol.Grid) {
    guard grid.hasCurrentRoomID,
          let room = grid.rooms.first(where: { $0.id == grid.currentRoomID }),
          let avatar = room.avatars.first(where: \.ownedByCurrentSession)
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
            if let userID { return avatar.user.id == userID }
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
        networkRefreshRevision &+= 1
        avatarStateSync.retryLatestFailure()
        mediaCoordinator.networkBecameAvailable()
        await loadHome()
        await refreshOwnedPresence()
      }
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
      await refreshOwnedPresence()
    }
  }

  func applicationDidWake() async {
    avatarStateSync.retryLatestFailure()
    mediaCoordinator.applicationDidWake()
    await loadHome()
    await refreshOwnedPresence()
  }

  private func reconcileAvatarStateOwnership() {
    let ownedRoomID = grids.values.lazy
      .filter(\.hasCurrentRoomID)
      .compactMap { grid -> Int64? in
        guard let room = grid.rooms.first(where: { $0.id == grid.currentRoomID }),
              room.avatars.contains(where: \.ownedByCurrentSession)
        else { return nil }
        return room.id
      }
      .first
    avatarStateSync.setOwnedRoom(ownedRoomID)
  }

  private func currentMediaTarget() -> GridMediaTarget? {
    for grid in grids.values where grid.hasCurrentRoomID {
      guard let room = grid.rooms.first(where: { $0.id == grid.currentRoomID }),
            room.hasConnection,
            room.avatars.contains(where: \.ownedByCurrentSession)
      else { continue }
      return GridMediaTarget(
        spaceID: grid.spaceID,
        roomID: room.id,
        generation: room.connection.generation
      )
    }
    return nil
  }

  func setInputSelection(_ selection: AudioInputSelection) {
    mediaCoordinator.setInput(selection)
  }

  func setOutputVolume(_ volume: Float) {
    mediaCoordinator.setOutputVolume(volume)
  }

  func refreshInputDevices() {
    mediaCoordinator.refreshInputDevices()
  }

  func retryAudio() {
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
    case let .join(roomID), let .leave(roomID): roomID
    }
  }

  private func applyPendingMembershipIntent() {
    guard let mutation = pendingMembershipMutations[membershipMutationRevision],
          grids[mutation.spaceID] != nil
    else { return }

    let change: GridOptimisticState.MembershipChange?
    switch mutation.intent {
    case let .join(fallbackAvatar, joinedAt):
      change = GridOptimisticState.joining(
        roomID: mutation.roomID,
        in: grids,
        avatar: fallbackAvatar,
        microphoneEnabled: mediaCoordinator.isMicrophoneEnabled,
        joinedAt: joinedAt
      )
    case .leave:
      change = GridOptimisticState.leaving(spaceID: mutation.spaceID, in: grids)
    }
    guard let change else { return }
    for (spaceID, grid) in change.nextGrids { grids[spaceID] = grid }
  }

  private func updateMembershipRollbackBaseline(with snapshots: [InlineProtocol.Grid]) {
    let confirmedSnapshots = snapshots.filter { snapshot in
      let previousRevision = lastAcceptedSnapshotRevisions[snapshot.spaceID]
      if let previousRevision { return snapshot.revision >= previousRevision }
      return true
    }
    membershipRollbackBaseline.mergeConfirmed(confirmedSnapshots)
  }

}

private struct OptimisticRoomMutationKey: Hashable {
  let roomID: Int64
  let field: GridOptimisticState.RoomField
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
