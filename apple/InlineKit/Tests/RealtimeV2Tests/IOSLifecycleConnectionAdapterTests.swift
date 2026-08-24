#if canImport(UIKit)
import AsyncAlgorithms
import Foundation
import InlineProtocol
import Testing
import UIKit

@testable import RealtimeV2

@Suite("RealtimeV2 iOS lifecycle adapter", .serialized)
@MainActor
final class IOSLifecycleConnectionAdapterTests {
  @Test("initial UIKit state gates startup until the application is active")
  func initialUIKitStateGatesStartup() async {
    let fixture = IOSLifecycleFixture(initialState: .background)

    await fixture.manager.start()
    fixture.adapter.start()
    #expect(await waitForCondition {
      await fixture.manager.currentSnapshot().state == .backgroundSuspended
    })
    #expect(await fixture.session.startTransportCount == 0)

    fixture.environment.state = .active
    fixture.post(UIApplication.didBecomeActiveNotification)
    #expect(await waitForCondition { await fixture.session.startTransportCount == 1 })

    await fixture.manager.shutdownForTesting()
  }

  @Test("brief backgrounding retains the open transport through UIKit notifications")
  func briefBackgroundingRetainsTransport() async {
    let fixture = IOSLifecycleFixture(initialState: .active)
    await fixture.open()
    let stopCount = await fixture.session.stopTransportCount

    fixture.enterBackground()
    #expect(await waitForCondition {
      let snapshot = await fixture.manager.currentSnapshot()
      return snapshot.state == .open && !snapshot.constraints.appActive
    })

    fixture.enterForeground()
    #expect(await waitForCondition {
      let snapshot = await fixture.manager.currentSnapshot()
      return snapshot.state == .open && snapshot.constraints.appActive
    })
    #expect(await fixture.session.startTransportCount == 1)
    #expect(await fixture.session.stopTransportCount == stopCount)

    await fixture.manager.shutdownForTesting()
  }

  @Test("background task denial stops and foreground replaces the transport")
  func backgroundTaskDenialReconnectsOnForeground() async {
    let fixture = IOSLifecycleFixture(initialState: .active, retainLease: false)
    await fixture.open()

    fixture.enterBackground()
    #expect(await waitForCondition {
      await fixture.manager.currentSnapshot().state == .backgroundSuspended
    })

    fixture.enterForeground()
    #expect(await waitForCondition { await fixture.session.startTransportCount == 2 })

    await fixture.manager.shutdownForTesting()
  }

  @Test("early lease expiration stops a background transport")
  func earlyLeaseExpirationStopsBackgroundTransport() async {
    let fixture = IOSLifecycleFixture(initialState: .active)
    await fixture.open()
    fixture.enterBackground()
    #expect(await waitForCondition { fixture.environment.leases.count == 1 })

    fixture.environment.leases[0].expire()
    #expect(await waitForCondition {
      await fixture.manager.currentSnapshot().state == .backgroundSuspended
    })

    await fixture.manager.shutdownForTesting()
  }

  @Test("foreground state wins an already queued lease expiration")
  func foregroundWinsQueuedExpiration() async {
    let fixture = IOSLifecycleFixture(initialState: .active)
    await fixture.open()
    let stopCount = await fixture.session.stopTransportCount
    fixture.enterBackground()
    #expect(await waitForCondition { fixture.environment.leases.count == 1 })

    fixture.environment.state = .active
    fixture.environment.leases[0].expire()
    fixture.post(UIApplication.didBecomeActiveNotification)

    #expect(await waitForCondition {
      let snapshot = await fixture.manager.currentSnapshot()
      return snapshot.state == .open && snapshot.constraints.appActive
    })
    #expect(await fixture.session.startTransportCount == 1)
    #expect(await fixture.session.stopTransportCount == stopCount)

    await fixture.manager.shutdownForTesting()
  }

  @Test("stale lease epochs cannot expire the current background retention")
  func staleLeaseEpochCannotExpireCurrentRetention() async {
    let fixture = IOSLifecycleFixture(initialState: .active)
    await fixture.open()

    fixture.enterBackground()
    #expect(await waitForCondition { fixture.environment.leases.count == 1 })
    let firstLease = fixture.environment.leases[0]
    fixture.enterForeground()
    #expect(await waitForCondition {
      await fixture.manager.currentSnapshot().constraints.appActive
    })

    fixture.enterBackground()
    #expect(await waitForCondition { fixture.environment.leases.count == 2 })
    firstLease.emitExpirationSignal()
    try? await Task.sleep(for: .milliseconds(30))
    #expect(await fixture.manager.currentSnapshot().state == .open)

    fixture.environment.leases[1].expire()
    #expect(await waitForCondition {
      await fixture.manager.currentSnapshot().state == .backgroundSuspended
    })

    await fixture.manager.shutdownForTesting()
  }

  @Test("UIKit lease reports denial, deadline, and early expiration")
  func concreteUIKitLeaseBehavior() async {
    let deniedAPI = IOSBackgroundTaskAPISpy()
    let (_, deniedSignal) = AsyncStream<IOSLifecycleSignal>.makeStream()
    let deniedLease = IOSBackgroundConnectionLease(
      epoch: 1,
      duration: .seconds(20),
      signal: deniedSignal,
      beginBackgroundTask: { _ in .invalid },
      endBackgroundTask: { deniedAPI.endedIdentifiers.append($0) }
    )
    #expect(!deniedLease.isRetained)
    deniedLease.end()
    #expect(deniedAPI.endedIdentifiers.isEmpty)

    let api = IOSBackgroundTaskAPISpy()
    let (signals, continuation) = AsyncStream<IOSLifecycleSignal>.makeStream()
    let lease = IOSBackgroundConnectionLease(
      epoch: 2,
      duration: .seconds(20),
      signal: continuation,
      now: { api.now },
      beginBackgroundTask: { handler in
        api.expirationHandler = handler
        return UIBackgroundTaskIdentifier(rawValue: 7)
      },
      endBackgroundTask: { api.endedIdentifiers.append($0) }
    )
    #expect(lease.isRetained)
    api.now = api.now.advanced(by: .seconds(21))
    #expect(!lease.isRetained)

    var iterator = signals.makeAsyncIterator()
    api.expirationHandler?()
    let expiration = await iterator.next()
    if case .some(.retentionExpired(2)) = expiration {
      // Expected.
    } else {
      Issue.record("Expected the concrete lease to emit its expiration epoch")
    }
    #expect(api.endedIdentifiers == [UIBackgroundTaskIdentifier(rawValue: 7)])
  }
}

@MainActor
private final class IOSLifecycleFixture {
  let session: IOSLifecycleFakeProtocolSession
  let manager: ConnectionManager
  let center: NotificationCenter
  let environment: IOSLifecycleTestEnvironment
  let adapter: LifecycleConnectionAdapter

  init(initialState: UIApplication.State, retainLease: Bool = true) {
    session = IOSLifecycleFakeProtocolSession()
    manager = ConnectionManager(
      session: session,
      constraints: ConnectionConstraints(
        authAvailable: true,
        networkAvailable: true,
        appActive: false,
        userWantsConnection: true
      )
    )
    center = NotificationCenter()
    environment = IOSLifecycleTestEnvironment(
      state: initialState,
      retainLease: retainLease
    )
    adapter = LifecycleConnectionAdapter(
      manager: manager,
      notificationCenter: center,
      applicationState: { [environment] in environment.state },
      makeLease: { [environment] epoch, duration, signal in
        #expect(duration == .seconds(20))
        return environment.makeLease(epoch: epoch, signal: signal)
      }
    )
  }

  func open() async {
    await self.manager.start()
    self.adapter.start()
    #expect(await waitForCondition { await self.session.startTransportCount == 1 })
    await self.session.emitTransportConnected()
    #expect(await waitForCondition { await self.session.startHandshakeCount == 1 })
    await self.session.emitProtocolOpen()
    #expect(await waitForCondition { await self.manager.currentSnapshot().state == .open })
  }

  func enterBackground() {
    environment.state = .inactive
    post(UIApplication.willResignActiveNotification)
    environment.state = .background
    post(UIApplication.didEnterBackgroundNotification)
  }

  func enterForeground() {
    environment.state = .active
    post(UIApplication.didBecomeActiveNotification)
  }

  func post(_ name: Notification.Name) {
    center.post(name: name, object: nil)
  }
}

@MainActor
private final class IOSLifecycleTestEnvironment {
  var state: UIApplication.State
  let retainLease: Bool
  private(set) var leases: [TestIOSBackgroundConnectionLease] = []

  init(state: UIApplication.State, retainLease: Bool) {
    self.state = state
    self.retainLease = retainLease
  }

  func makeLease(
    epoch: UInt64,
    signal: AsyncStream<IOSLifecycleSignal>.Continuation
  ) -> TestIOSBackgroundConnectionLease {
    let lease = TestIOSBackgroundConnectionLease(
      epoch: epoch,
      retained: retainLease,
      signal: signal
    )
    leases.append(lease)
    return lease
  }
}

@MainActor
private final class TestIOSBackgroundConnectionLease: IOSBackgroundConnectionRetaining {
  let epoch: UInt64
  private var retained: Bool
  private var ended = false
  private let signal: AsyncStream<IOSLifecycleSignal>.Continuation

  init(
    epoch: UInt64,
    retained: Bool,
    signal: AsyncStream<IOSLifecycleSignal>.Continuation
  ) {
    self.epoch = epoch
    self.retained = retained
    self.signal = signal
  }

  var isRetained: Bool {
    retained && !ended
  }

  func end() {
    ended = true
  }

  func expire() {
    retained = false
    signal.yield(.retentionExpired(epoch))
  }

  func emitExpirationSignal() {
    signal.yield(.retentionExpired(epoch))
  }
}

@MainActor
private final class IOSBackgroundTaskAPISpy {
  var now = ContinuousClock().now
  var expirationHandler: IOSBackgroundConnectionLease.ExpirationHandler?
  var endedIdentifiers: [UIBackgroundTaskIdentifier] = []
}

@MainActor
private func waitForCondition(
  timeout: Duration = .seconds(1),
  pollInterval: Duration = .milliseconds(10),
  _ condition: @escaping @MainActor () async -> Bool
) async -> Bool {
  let clock = ContinuousClock()
  let deadline = clock.now + timeout

  while await condition() == false {
    if clock.now >= deadline {
      return false
    }
    try? await clock.sleep(for: pollInterval)
  }
  return true
}

private actor IOSLifecycleFakeProtocolSession: ProtocolSessionType {
  nonisolated let events = AsyncChannel<ProtocolSessionEventEnvelope>()
  private(set) var startTransportCount = 0
  private(set) var startTransportSessionIDs: [UInt64] = []
  private(set) var stopTransportCount = 0
  private(set) var startHandshakeCount = 0
  private(set) var handshakeSessionIDs: [UInt64] = []

  func startTransport(sessionID: UInt64) async {
    startTransportCount += 1
    startTransportSessionIDs.append(sessionID)
  }

  func stopTransport() async {
    stopTransportCount += 1
  }

  func startHandshake(sessionID: UInt64) async {
    startHandshakeCount += 1
    handshakeSessionIDs.append(sessionID)
  }

  func sendPing(nonce _: UInt64) async {}

  func sendRpc(method _: InlineProtocol.Method, input _: RpcCall.OneOf_Input?) async throws -> UInt64 {
    0
  }

  func callRpc(
    method _: InlineProtocol.Method,
    input _: RpcCall.OneOf_Input?,
    timeout _: Duration?
  ) async throws -> InlineProtocol.RpcResult.OneOf_Result? {
    nil
  }

  func emitTransportConnected() async {
    guard let sessionID = startTransportSessionIDs.last else {
      Issue.record("Cannot emit transport connected before transport startup")
      return
    }
    await events.send(.lifecycle(.transportConnected(sessionID: sessionID)))
  }

  func emitProtocolOpen() async {
    guard let sessionID = handshakeSessionIDs.last else {
      Issue.record("Cannot emit protocol open before handshake startup")
      return
    }
    await events.send(.lifecycle(.protocolOpen(sessionID: sessionID)))
  }
}
#endif
