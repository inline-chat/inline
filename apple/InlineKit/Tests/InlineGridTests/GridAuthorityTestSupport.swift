@testable import Auth
import Foundation
@testable import InlineGrid
import InlineProtocol
@testable import InlineRTC
@testable import RealtimeV2
import Testing

/// The production product/command/auth boundary, with only native I/O and network replaced.
/// Control storage stays unavailable so no Home/GetGrid response can repair a failed fence.
@MainActor
final class GridAuthorityTestFixture {
  private let namespace = UUID().uuidString
  private let defaults: UserDefaults
  let cache: AuthSnapshotCache
  let writes = GridAuthorityWriteProbe()
  let store: AuthStore
  let auth: AuthHandle
  let audio: GridAuthorityAudioDriver
  let rtc = GridAuthorityRTCDriver()
  let engine: InlineRTCSession
  let realtime: RealtimeV2
  let service: GridRoomService
  private let control: GridAuthorityMembershipControl?

  init(configurationBlocked: Bool = false, control: GridAuthorityMembershipControl? = nil) {
    self.control = control
    defaults = UserDefaults(suiteName: "grid-authority-test-\(namespace)")!
    cache = AuthSnapshotCache(initial: AuthSnapshot(status: .hydrating, didHydrate: false))
    let writes = writes
    store = AuthStore(
      cache: cache, mocked: true, namespace: namespace,
      credentialWriteInterleavingHook: { writes.record() }
    )
    auth = AuthHandle(cache: cache, store: store)
    audio = GridAuthorityAudioDriver(configurationBlocked: configurationBlocked)
    engine = InlineRTCSession(
      audioDriver: audio, permissionDriver: GridAuthorityPermission(), rtcDriver: rtc,
      captureCooldown: .zero
    )
    realtime = RealtimeV2(
      transport: MockTransport(), auth: auth,
      applyUpdates: GridAuthorityNoUpdates(), syncStorage: GridAuthoritySyncStorage(),
      storageIsReady: { false }
    )
    let send: GridRoomAPI.Send? = if let control {
      { transaction, token in try await control.send(transaction, account: token) }
    } else {
      nil
    }
    service = GridRoomService(
      realtime: realtime, userDefaults: defaults, engine: engine, auth: auth,
      sendGridTransaction: send
    )
  }

  func credentials(sessionID: Int64) throws -> InlineProtocolSessionCredentials {
    let key = Array(UInt8.min ... UInt8.max)
    return try InlineProtocolSessionCredentials(
      userId: 1, accountSessionId: sessionID,
      permanent: InlineProtocolAuthorization(
        key: key, keyID: InlineSecureTransport.authKeyID(key), serverSalt: 7,
        temporary: false, expiresAt: nil
      )
    )
  }

  @discardableResult
  func seedAccount() async throws -> AuthAccountMutationToken {
    try await auth.saveInlineProtocolCredentials(credentials(sessionID: 10))
    return try auth.beginAccountMutation()
  }

  func admit(membershipID: String = "membership-a", intentRevision: Int = 0) async throws {
    let token = try auth.beginAccountMutation()
    let response = claimResult(membershipID: membershipID)
    let operation = GridMembershipOperation(
      kind: .join(roomID: 7), spaceID: 42, expectedMembershipID: "",
      intentRevision: intentRevision, accountToken: token, microphoneEnabled: false,
      automaticMicrophoneChange: nil, accessRevision: 0, revision: intentRevision + 1,
      startedAt: Date()
    )
    await service.handle(.joined(operation, response))
    try await eventuallyGridAuthority { self.service.media.connectionState == .connected }
    #expect(service.hasLocalAdmission)
  }

  func claimResult(membershipID: String, revision: Int64 = 1) -> GridRoomMutationResult {
    let call = GridCurrentCall.with {
      $0.callID = "call-\(membershipID)"
      $0.membershipID = membershipID
      $0.spaceID = 42
      $0.roomID = 7
      $0.ownedByCurrentSession = true
    }
    let grid = InlineProtocol.Grid.with {
      $0.spaceID = 42
      $0.enabled = true
      $0.currentRoomID = 7
      $0.revision = revision
      $0.rooms = [.with {
        $0.id = 7
        $0.spaceID = 42
        $0.connection = .with { $0.roomID = 7
          $0.generation = 3
        }
        $0.avatars = [
          .with {
            $0.user = .with { $0.id = 1 }
            $0.membershipID = membershipID
            $0.ownedByCurrentSession = true
          },
          .with { $0.user = .with { $0.id = 2 }
            $0.membershipID = "remote"
          },
        ]
      }]
    }
    let credentials = GridConnectionCredentials.with {
      $0.connection = grid.rooms[0].connection
      $0.callID = call.callID
      $0.membershipID = membershipID
      $0.serverURL = "wss://grid.invalid"
      $0.participantIdentity = "inline-grid-user-1-\(membershipID)"
      $0.token = "fixture-only"
      $0.expiresAt = Int64(Date().addingTimeInterval(120).timeIntervalSince1970)
    }
    return GridRoomMutationResult(grids: [grid], credentials: credentials, currentCall: call)
  }

  func enableTransferForPublicActions() async throws {
    guard let control, let call = service.currentCall else { throw GridRoomAPIError.invalidResponse }
    control.setupHome = .with {
      $0.spaces = [.with { $0.spaceID = 42
        $0.activeAvatarCount = 2
      }]
      $0.currentCall = call
      $0.callTransferEnabled = true
    }
    await service.handle(GridRoomLifecycleEvent.realtimeConnection(.connected))
    control.setupHome = nil
    #expect(service.callTransferEnabled)
  }

  func close() async {
    control?.failAll()
    await audio.allowConfiguration()
    await audio.releaseShutdown(succeeded: true)
    await service.prepareForLogout()
    await realtime.loggedOut()
    AuthKeychainConfig.mockDelete("token", namespace: namespace)
    AuthKeychainConfig.mockDelete("credentials_v2", namespace: namespace)
    AuthKeychainConfig.mockDelete("inline_protocol_credentials_v1", namespace: namespace)
    let prefix = AuthKeychainConfig.userDefaultsPrefix(mocked: true, namespace: namespace)
    for suffix in ["userId", "logoutPending", "logoutAttemptID", "loginCommitPendingAttemptID"] {
      UserDefaults.standard.removeObject(forKey: "\(prefix)\(suffix)")
    }
  }
}

/// The typed API's actual transaction send boundary. It deliberately ignores task cancellation
/// while a reply is held, reproducing a provider completion after its worker was invalidated.
@MainActor
final class GridAuthorityMembershipControl {
  struct Submission {
    let method: InlineProtocol.Method
    let account: AuthAccountMutationToken
  }

  var setupHome: GetGridHomeResult?
  private(set) var submissions: [Submission] = []
  private(set) var completed = Set<Int>()
  private var pending: [Int: CheckedContinuation<RpcResult.OneOf_Result?, any Error>] = [:]

  func send(_ transaction: any Transaction2, account: AuthAccountMutationToken) async throws -> RpcResult
    .OneOf_Result?
  {
    switch transaction.method {
      case .getGridHome:
        guard let setupHome else { throw GridRoomAPIError.invalidResponse }
        return .getGridHome(setupHome)
      case .createGridRoom, .joinGridRoom, .leaveGridRoom, .moveGridCallHere:
        let index = submissions.count
        submissions.append(Submission(method: transaction.method, account: account))
        defer { completed.insert(index) }
        return try await withCheckedThrowingContinuation { pending[index] = $0 }
      default:
        // GetGrid/Home repair remains unavailable throughout the auth transition and late reply.
        throw GridRoomAPIError.invalidResponse
    }
  }

  func succeed(_ index: Int, with response: GridRoomMutationResult) {
    guard let continuation = pending.removeValue(forKey: index) else { return }
    let result: RpcResult.OneOf_Result
    switch submissions[index].method {
      case .createGridRoom:
        result = .createGridRoom(.with {
          $0.grids = response.grids
          if let call = response.currentCall {
            $0.currentCall = call
          }
          if let credentials = response.credentials {
            $0.connection = credentials
          }
        })
      case .joinGridRoom:
        result = .joinGridRoom(.with {
          $0.grids = response.grids
          if let call = response.currentCall {
            $0.currentCall = call
          }
          if let credentials = response.credentials {
            $0.connection = credentials
          }
        })
      case .leaveGridRoom:
        result = .leaveGridRoom(.with {
          $0.grids = response.grids
          if let call = response.currentCall {
            $0.currentCall = call
          }
        })
      case .moveGridCallHere:
        result = .moveGridCallHere(.with {
          $0.grids = response.grids
          $0.moved = response.moved
          if let call = response.currentCall {
            $0.currentCall = call
          }
          if let credentials = response.credentials {
            $0.connection = credentials
          }
        })
      default:
        continuation.resume(throwing: GridRoomAPIError.invalidResponse)
        return
    }
    continuation.resume(returning: result)
  }

  func fail(_ index: Int) {
    pending.removeValue(forKey: index)?.resume(throwing: GridRoomAPIError.invalidResponse)
  }

  func failAll() {
    let continuations = Array(pending.values)
    pending.removeAll()
    continuations.forEach { $0.resume(throwing: CancellationError()) }
  }
}

@MainActor
func eventuallyGridAuthority(_ predicate: @escaping @MainActor () async -> Bool) async throws {
  let deadline = ContinuousClock.now.advanced(by: .seconds(3))
  while await !predicate() {
    guard ContinuousClock.now < deadline else {
      throw GridAuthorityTestTimeout()
    }
    try await Task.sleep(for: .milliseconds(5))
  }
}

private struct GridAuthorityTestTimeout: Error {}

actor GridAuthorityAudioDriver: GridAudioDriver {
  private var configurationBlocked: Bool
  private var configurationWaiters: [CheckedContinuation<Void, Never>] = []
  private var shutdownBlocked = false
  private var shutdownSucceeds = true
  private var shutdownWaiters: [CheckedContinuation<Void, Never>] = []
  private(set) var shutdownCalls = 0
  private(set) var configurationCalls = 0
  private var recording = false
  private var playing = false

  init(configurationBlocked: Bool) {
    self.configurationBlocked = configurationBlocked
  }

  func configure(_: InlineRTCConfiguration) async throws {
    configurationCalls += 1
    if configurationBlocked {
      await withCheckedContinuation { configurationWaiters.append($0) }
    }
  }

  func allowConfiguration() {
    configurationBlocked = false
    let waiters = configurationWaiters
    configurationWaiters.removeAll()
    waiters.forEach { $0.resume() }
  }

  func setMediaDemandActive(_ active: Bool, epoch _: UInt64) async throws {
    playing = active
  }

  func setPrepared(_ prepared: Bool) async throws {
    if prepared || !shutdownBlocked {
      recording = prepared
    }
  }

  func blockShutdown() {
    shutdownBlocked = true
  }

  func releaseShutdown(succeeded: Bool) {
    shutdownBlocked = false
    shutdownSucceeds = succeeded
    let waiters = shutdownWaiters
    shutdownWaiters.removeAll()
    waiters.forEach { $0.resume() }
  }

  func stopForShutdown() async -> GridAudioDriverShutdownReceipt {
    shutdownCalls += 1
    if shutdownBlocked {
      await withCheckedContinuation { shutdownWaiters.append($0) }
    }
    if shutdownSucceeds {
      recording = false
      playing = false
    }
    return .init(
      recordingStopped: shutdownSucceeds, playoutStopped: shutdownSucceeds,
      failures: shutdownSucceeds ? [] : ["Fixture native teardown denied"]
    )
  }

  func runtimeHealth() async -> GridAudioRuntimeHealth {
    .init(isEngineRunning: true, isRecording: recording, isPlaying: playing, route: nil)
  }

  func applyInputRoute(
    _: AudioInputRouteTarget,
    restartPreparedAudio _: Bool
  ) async throws -> GridAudioInputRouteApplication {
    .committed
  }

  func inputDeviceInventory() async -> AudioInputDeviceInventory {
    .init(automaticDeviceID: "fixture", automaticDeviceName: "Fixture", devices: [], routeEpoch: 0)
  }
}

actor GridAuthorityRTCDriver: GridRTCDriver {
  private(set) var connectedIdentities: [String] = []
  private(set) var microphoneMuted = true
  func makeRoom(configuration _: InlineRTCConfiguration) async throws -> GridRTCRoomHandle {
    .init()
  }

  func connect(_: GridRTCRoomHandle, credentials: InlineRTCCredentials) async throws {
    connectedIdentities.append(credentials.participantIdentity)
  }

  func publishPreparedMicrophone(_: GridRTCRoomHandle, initiallyMuted: Bool) async throws {
    microphoneMuted = initiallyMuted
  }

  func setMicrophoneMuted(_ muted: Bool, in _: GridRTCRoomHandle) async throws {
    microphoneMuted = muted
  }

  func screenCaptureSources() async throws -> [InlineRTCScreenCaptureSource] {
    []
  }

  func setScreenShare(
    _: InlineRTCScreenCaptureSource?,
    qualityProfile _: InlineRTCScreenShareQualityProfile,
    in _: GridRTCRoomHandle
  ) async throws {}
  func quiesceLocally(_ room: GridRTCRoomHandle) async -> GridLocalRoomQuiescenceReceipt {
    microphoneMuted = true
    return .init(room: room, localResourcesReleased: true, failures: [])
  }
}

struct GridAuthorityPermission: GridMicrophonePermissionDriver {
  func status() async -> InlineRTCMicrophonePermission {
    .authorized
  }

  func request() async -> InlineRTCMicrophonePermission {
    .authorized
  }
}

final class GridAuthorityWriteProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0
  var value: Int {
    lock.withLock { count }
  }

  func record() {
    lock.withLock { count += 1 }
  }
}

private struct GridAuthorityNoUpdates: ApplyUpdates {
  func apply(
    updates: [InlineProtocol.Update],
    source _: UpdateApplySource,
    sidecars _: InlineProtocol.UpdateSidecars?
  ) async -> UpdateApplyResult {
    .success(count: updates.count)
  }
}

private struct GridAuthoritySyncStorage: SyncStorage {
  func getState() async throws -> SyncState {
    .init(lastSyncDate: 0)
  }

  func setState(_: SyncState) async -> Bool {
    true
  }

  func getBucketState(for _: BucketKey) async throws -> BucketState {
    .init(date: 0, seq: 0)
  }

  func setBucketState(for _: BucketKey, state _: BucketState) async -> Bool {
    true
  }

  func advanceBucketState(for _: BucketKey, state: BucketState) async -> BucketState? {
    state
  }

  func removeBucketState(for _: BucketKey) async -> Bool {
    true
  }

  func setBucketStates(states _: [BucketKey: BucketState]) async -> Bool {
    true
  }

  func clearSyncState() async -> Bool {
    true
  }
}
