import Auth
import Logger

/// Serializes the transient state owned by the current Grid avatar.
///
/// Rapid UI changes are coalesced to the latest value while one RPC is in
/// flight, so task scheduling cannot reorder mute/unmute updates on the wire.
/// Failed latest state is retained for a network/wake retry, but ownership
/// changes immediately discard work for a room this process no longer owns.
@MainActor
final class GridAvatarStateSync {
  private struct Request: Equatable {
    let roomID: Int64
    let membershipID: String
    let accountToken: AuthAccountMutationToken
    let microphoneEnabled: Bool
  }

  private let api: GridRoomAPI
  private let log = Log.scoped("GridAvatarStateSync")
  private var ownedRoomID: Int64?
  private var ownedMembershipID: String?
  private var ownedAccountToken: AuthAccountMutationToken?
  private var queued: Request?
  private var failed: Request?
  private var generation = 0
  private var syncTask: Task<Void, Never>?
  private var workerGeneration: Int?

  init(api: GridRoomAPI) {
    self.api = api
  }

  deinit {
    syncTask?.cancel()
  }

  func setOwnedRoom(_ roomID: Int64?, membershipID: String? = nil, accountToken: AuthAccountMutationToken? = nil) {
    guard ownedRoomID != roomID || ownedMembershipID != membershipID || ownedAccountToken != accountToken
    else { return }
    generation &+= 1
    ownedRoomID = roomID
    ownedMembershipID = membershipID
    ownedAccountToken = accountToken
    if queued?.roomID != roomID || queued?.membershipID != membershipID {
      queued = nil
    }
    if failed?.roomID != roomID || failed?.membershipID != membershipID {
      failed = nil
    }
    syncTask?.cancel()
    syncTask = nil
    workerGeneration = nil
    startIfNeeded()
  }

  func submitMicrophoneState(roomID: Int64, enabled: Bool) {
    guard ownedRoomID == roomID, let membershipID = ownedMembershipID, let accountToken = ownedAccountToken,
          !membershipID.isEmpty else { return }
    queued = Request(roomID: roomID, membershipID: membershipID, accountToken: accountToken, microphoneEnabled: enabled)
    failed = nil
    startIfNeeded()
  }

  func retryLatestFailure() {
    guard queued == nil, let failed, failed.roomID == ownedRoomID,
          failed.membershipID == ownedMembershipID else { return }
    queued = failed
    self.failed = nil
    startIfNeeded()
  }

  private func startIfNeeded() {
    guard syncTask == nil, queued != nil else { return }
    let workerGeneration = generation
    self.workerGeneration = workerGeneration
    syncTask = Task { [weak self] in
      await self?.run(workerGeneration: workerGeneration)
    }
  }

  private func run(workerGeneration: Int) async {
    while !Task.isCancelled, generation == workerGeneration, let request = queued {
      queued = nil
      do {
        try await api.setMicrophoneEnabled(
          request.microphoneEnabled,
          roomID: request.roomID,
          expectedMembershipID: request.membershipID,
          accountToken: request.accountToken
        )
        log.debug(
          "GRID_TRACE phase=avatar_microphone_sent room=\(request.roomID) enabled=\(request.microphoneEnabled)"
        )
      } catch {
        guard !Task.isCancelled, generation == workerGeneration else { continue }
        // Preserve only the latest still-relevant request. A newer UI intent
        // already waiting in `queued` supersedes the failed value.
        if ownedRoomID == request.roomID, ownedMembershipID == request.membershipID, queued == nil {
          failed = request
        }
        log.warning(
          "GRID_TRACE phase=avatar_microphone_send_failed room=\(request.roomID) enabled=\(request.microphoneEnabled)"
        )
        PerformanceTrace.breadcrumb(
          "Grid avatar microphone sync failed",
          category: "Grid.State",
          level: .warning
        )
      }
    }
    guard self.workerGeneration == workerGeneration else { return }
    syncTask = nil
    self.workerGeneration = nil
    startIfNeeded()
  }
}
