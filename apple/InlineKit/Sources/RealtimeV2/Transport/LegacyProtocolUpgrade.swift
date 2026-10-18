import Auth
import Foundation
import InlineConfig
import InlineProtocol
import Logger

protocol LegacyProtocolUpgrading: Sendable {
  func start() async
  func stop() async
}

protocol LegacyProtocolUpgradeConnection: Sendable {
  var authorization: InlineProtocolAuthorization { get async }
  func invoke(_ request: RealtimeV3Request) async throws -> RealtimeV3Response
  func bindTemporary(to permanent: InlineProtocolAuthorization) async throws
  func close() async
}

extension InlineProtocolV3Connection: LegacyProtocolUpgradeConnection {}

enum LegacyProtocolUpgradeDecline: Error, Sendable {
  case declined(AuthUpgradeDeclined.Reason)
  case notBound
}

/// Only bounded program categories reach logs. In particular, RPC messages and arbitrary
/// errors may contain server-supplied or private text and must never be interpolated here.
private struct LegacyProtocolUpgradeOutcome {
  let level: LogLevel
  let outcome: String
  let reason: String

  init(error: (any Error)?) {
    guard let error else {
      level = .info; outcome = "prepared"; reason = "verified"
      return
    }
    outcome = error is CancellationError ? "cancelled" : "deferred"
    switch error {
    case is CancellationError:
      level = .info; reason = "cancelled"
    case let decline as LegacyProtocolUpgradeDecline:
      switch decline {
      case .declined(.disabled): level = .info; reason = "disabled"
      case .declined(.ineligible): level = .info; reason = "ineligible"
      case .declined(.sourceRejected): level = .warning; reason = "source_rejected"
      case .notBound: level = .warning; reason = "not_bound"
      default: level = .warning; reason = "declined"
      }
    case let storage as AuthStorageError:
      reason = storage.privacySafeErrorCategory
      switch storage {
      case .loginUnavailable, .loginSuperseded, .logoutInProgress:
        level = .info
      default: level = .error
      }
    case let connection as InlineProtocolV3ConnectionError:
      reason = connection.privacySafeErrorCategory
      switch connection {
      case .invalidKey, .unexpectedResponse, .protocolFailure, .inboundMessageTooLarge:
        level = .error
      default: level = .warning
      }
    case let network as URLError:
      level = network.code == .cancelled ? .info : .warning
      reason = network.code == .cancelled ? "cancelled" : "network"
    default:
      level = .error; reason = "unexpected"
    }
  }
}

/// Carries only the fixed outcome reason, so Sentry groups unexpected upgrade failures by cause
/// instead of folding every reason into one uncategorized issue.
struct LegacyProtocolUpgradeFailure: Error, PrivacySafeErrorCategoryProviding {
  let reason: String

  var privacySafeErrorCategory: String { "legacy_v3_upgrade:\(reason)" }
}

/// The candidate is durable before the first request that can bind it. Retrying after a lost
/// response therefore proves possession of the same key instead of creating another authority.
struct LegacyProtocolUpgradeAttempt: Sendable {
  typealias Connect = @Sendable (InlineProtocolV3Options) async throws -> any LegacyProtocolUpgradeConnection

  let url: URL
  let resolveRoots: @Sendable () async throws -> [InlineProtocolRSAPublicKey]
  let connect: Connect
  let candidate: @Sendable (AuthCredentials) async throws -> InlineProtocolAuthorization?
  let stage: @Sendable (InlineProtocolAuthorization, AuthCredentials) async throws -> InlineProtocolAuthorization
  let commit: @Sendable (InlineProtocolSessionCredentials, AuthCredentials) async throws -> Void
  let validateSource: @Sendable () throws -> Void

  func run(source: AuthCredentials) async throws {
    try requireCurrentSource()
    let roots = try await resolveRoots()
    let staged = try await candidate(source)
    try requireCurrentSource()
    var permanentConnection: (any LegacyProtocolUpgradeConnection)?
    var temporaryConnection: (any LegacyProtocolUpgradeConnection)?
    do {
      if let staged {
        permanentConnection = try await connect(.reconnect(url: url, authorization: staged))
      } else {
        let fresh = try await connect(.init(url: url, rsaPublicKeys: roots))
        permanentConnection = fresh
        try requireCurrentSource()
        let authorization = await fresh.authorization
        let chosen = try await stage(authorization, source)
        try requireCurrentSource()
        if chosen.keyID != authorization.keyID || chosen.key != authorization.key {
          await fresh.close()
          permanentConnection = try await connect(.reconnect(url: url, authorization: chosen))
        }
      }
      try requireCurrentSource()
      guard let permanentConnection else { throw InlineProtocolV3ConnectionError.invalidKey }
      // This field exists only inside the pinned, encrypted V3 carrier. Supplying it on every
      // retry also makes the server prove that a recovered binding is for this exact session.
      let response = try await permanentConnection.invoke(.with {
        $0.body = .authUpgradeSession(.with { $0.bearerToken = source.token })
      })
      try requireCurrentSource()
      if case let .rpcError(error) = response.body { throw InlineProtocolV3ConnectionError.rpc(error) }
      guard case let .authUpgradeSession(result) = response.body else {
        throw InlineProtocolV3ConnectionError.unexpectedResponse
      }
      switch result.state {
      case let .declined(declined): throw LegacyProtocolUpgradeDecline.declined(declined.reason)
      case .notBound: throw LegacyProtocolUpgradeDecline.notBound
      default: break
      }
      guard case let .authorized(authorized) = result.state,
            authorized.hasUser, authorized.user.id == source.userId,
            authorized.accountSessionID > 0
      else { throw InlineProtocolV3ConnectionError.unexpectedResponse }
      let permanent = await permanentConnection.authorization
      await permanentConnection.close()
      try requireCurrentSource()

      let temporary = try await connect(.init(url: url, rsaPublicKeys: roots, temporary: true))
      temporaryConnection = temporary
      try requireCurrentSource()
      try await temporary.bindTemporary(to: permanent)
      try requireCurrentSource()
      // A successful application response proves both the encrypted carrier and its binding;
      // a separate ping here adds a round trip without strengthening that proof.
      let me = try await temporary.invoke(.with {
        $0.body = .rpc(.with {
          $0.method = .getMe
          $0.input = .getMe(.init())
        })
      })
      if case let .rpcError(error) = me.body { throw InlineProtocolV3ConnectionError.rpc(error) }
      guard case let .rpcResult(rpc) = me.body,
            case let .getMe(result) = rpc.result,
            result.hasUser, result.user.id == source.userId
      else { throw InlineProtocolV3ConnectionError.unexpectedResponse }
      let temporaryAuthorization = await temporary.authorization
      try requireCurrentSource()
      // The session ID comes from the source-bound upgrade response; the temporary key proves
      // its binding to that same permanent key, and getMe proves the application identity.
      try await commit(.init(
        userId: source.userId,
        accountSessionId: authorized.accountSessionID,
        permanent: permanent,
        temporary: temporaryAuthorization
      ), source)
      await temporary.close()
    } catch {
      await permanentConnection?.close()
      await temporaryConnection?.close()
      throw error
    }
  }

  private func requireCurrentSource() throws {
    try Task.checkCancellation()
    try validateSource()
  }
}

/// An optional background enhancement. Its failures never enter the application transport's
/// event stream or change login state. Only lifecycle opportunities initiate retries.
actor LegacyProtocolUpgradeCoordinator: LegacyProtocolUpgrading {
  private let log = Log.scoped("Realtime.ProtocolUpgrade")
  private let snapshots: @Sendable () -> AsyncStream<AuthSnapshot>
  private let run: @Sendable (AuthCredentials) async throws -> Void
  private let timeout: Duration
  private let retryDelay: Duration
  private var observer: Task<Void, Never>?
  private var attempt: Task<Void, Never>?
  private var attemptSource: AuthCredentials?
  private var retryAfter: ContinuousClock.Instant?
  private var retrySource: AuthCredentials?
  private var generation: UInt64 = 0

  init(auth: AuthHandle, rsaPublicKeys: [InlineProtocolRSAPublicKey]) {
    let url = URL(string: InlineConfig.realtimeServerURL.replacingOccurrences(
      of: "/realtime", with: "/realtime/v3"
    ))!
    #if DEBUG
    let debugHost = ProjectConfig.useProductionApi ? nil : ProjectConfig.devHost
    #else
    let debugHost: String? = nil
    #endif
    snapshots = { auth.snapshots }
    run = { source in
      let authority = try auth.beginAccountMutation()
      let operation = LegacyProtocolUpgradeAttempt(
        url: url,
        resolveRoots: {
          try await InlineProtocolTrustRoots.resolve(
            for: url, pinnedKeys: rsaPublicKeys, allowedDevelopmentHost: debugHost
          )
        },
        connect: { try await InlineProtocolV3Connection.connect($0) },
        candidate: { try await auth.legacyProtocolUpgradeCandidate(for: $0, authority: authority) },
        stage: { try await auth.stageLegacyProtocolUpgrade($0, for: $1, authority: authority) },
        commit: { try await auth.commitLegacyProtocolUpgrade($0, for: $1, authority: authority) },
        validateSource: {
          try auth.validateAccountMutation(authority)
          guard case let .authenticated(current) = auth.snapshot().status,
                current.userId == source.userId, current.token == source.token,
                !auth.hasPendingAccountTransition()
          else { throw CancellationError() }
        }
      )
      try await operation.run(source: source)
    }
    timeout = .seconds(20)
    retryDelay = .seconds(300)
  }

  init(
    snapshots: @escaping @Sendable () -> AsyncStream<AuthSnapshot>,
    timeout: Duration = .seconds(20),
    retryDelay: Duration = .seconds(300),
    run: @escaping @Sendable (AuthCredentials) async throws -> Void
  ) {
    self.snapshots = snapshots
    self.timeout = timeout
    self.retryDelay = retryDelay
    self.run = run
  }

  func start() {
    // Re-subscribe for a fresh snapshot at each natural connection opportunity. Snapshot
    // delivery is buffered by Auth, so no account transition can be missed during the swap.
    observer?.cancel()
    let stream = snapshots()
    observer = Task { [weak self] in
      for await snapshot in stream {
        guard !Task.isCancelled else { return }
        await self?.consider(snapshot)
      }
    }
  }

  func stop() async {
    generation &+= 1
    observer?.cancel()
    observer = nil
    let stopping = attempt
    if stopping != nil { log.info("event=legacy_v3_upgrade outcome=cancelled reason=stopped") }
    stopping?.cancel()
    attempt = nil
    attemptSource = nil
    await stopping?.value
  }

  private func consider(_ snapshot: AuthSnapshot) async {
    let source: AuthCredentials? = if case let .authenticated(source) = snapshot.status { source } else { nil }
    if let attemptSource,
       attemptSource.userId != source?.userId || attemptSource.token != source?.token {
      generation &+= 1
      let stopping = attempt
      log.info("event=legacy_v3_upgrade outcome=cancelled reason=account_changed")
      stopping?.cancel()
      await stopping?.value
      guard !Task.isCancelled else { return }
      attempt = nil
      self.attemptSource = nil
      retryAfter = nil
      retrySource = nil
    }
    // Our own verified commit publishes a snapshot before its task closes the temporary
    // socket. Let that same-source attempt finish, including its prepared diagnostic.
    guard let source, snapshot.inlineProtocol == nil, attempt == nil else { return }
    let sameRetrySource = retrySource?.userId == source.userId && retrySource?.token == source.token
    guard !sameRetrySource || (retryAfter.map({ ContinuousClock.now >= $0 }) ?? true) else { return }
    generation &+= 1
    let current = generation
    attemptSource = source
    attempt = Task(priority: .utility) { [weak self, run, timeout] in
      let started = ContinuousClock.now
      await self?.started()
      do {
        try await withThrowingTaskGroup(of: Void.self) { group in
          group.addTask { try await run(source) }
          group.addTask {
            try await Task.sleep(for: timeout)
            throw InlineProtocolV3ConnectionError.timeout
          }
          defer { group.cancelAll() }
          _ = try await group.next()
        }
        await self?.finished(generation: current, error: nil, duration: started.duration(to: .now))
      } catch {
        await self?.finished(generation: current, error: error, duration: started.duration(to: .now))
      }
    }
  }

  private func started() {
    log.info("event=legacy_v3_upgrade outcome=started")
  }

  private func finished(generation: UInt64, error: (any Error)?, duration: Duration) {
    guard self.generation == generation else { return }
    attempt = nil
    retrySource = attemptSource
    attemptSource = nil
    retryAfter = ContinuousClock.now + retryDelay
    let result = LegacyProtocolUpgradeOutcome(error: error)
    let milliseconds = duration.components.seconds * 1_000 + duration.components.attoseconds / 1_000_000_000_000_000
    let message = "event=legacy_v3_upgrade outcome=\(result.outcome) reason=\(result.reason) duration_ms=\(milliseconds)"
    switch result.level {
    case .error: log.error(message, error: LegacyProtocolUpgradeFailure(reason: result.reason))
    case .warning: log.warning(message)
    default: log.info(message)
    }
  }
}
