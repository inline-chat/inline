import Foundation
@testable import InlineAudioPlayback
import Testing

@MainActor
@Suite("Grid process audio ownership", .timeLimit(.minutes(1)))
struct InlineAudioSessionGridTests {
  @Test(
    "Grid preflight and admission preserve an active recording, preview, or movie",
    arguments: [InlineAudioSession.Owner.recording, .draftPreview, .video]
  )
  func competingConsumer(owner: InlineAudioSession.Owner) async throws {
    let backend = GridSessionTestBackend()
    let session = InlineAudioSession(backend: backend)
    defer { Task { await backend.drain() } }
    let token = try session.acquire(owner)

    #expect(throws: (any Error).self) { try session.validateGridAdmission() }
    await #expect(throws: (any Error).self) {
      try await session.setGridDemandActive(true, epoch: 1)
    }
    #expect(session.owns(token))
    #expect(!session.isGridActive)
    #expect(await backend.operations.isEmpty)
    let release = try #require(session.release(token))
    try await expectOperation(.release(token), at: 0, backend: backend)
    try await backend.completeNext()
    try await finishOperation(release, backend: backend)
  }

  @Test("Grid takeover waits for suspended voice activation and its native release")
  func takeoverWaitsForOrdinaryAudio() async throws {
    let backend = GridSessionTestBackend()
    let session = InlineAudioSession(backend: backend)
    defer { Task { await backend.drain() } }
    let voice = try session.acquire(.voice)
    session.willAcquire = { owner in
      if owner == .call {
        session.release(voice)
      }
    }
    let voiceStart = try await beginOperation {
      try await session.activate(voice, configuration: .voicePlayback)
    }
    try await expectOperation(.activate(voice), at: 0, backend: backend)

    let gridStart = try await beginOperation {
      try await session.setGridDemandActive(true, epoch: 1)
    }
    let call = try #require(session.current)
    #expect(call.owner == .call)
    #expect(!session.owns(voice))
    #expect(await backend.operations == [.activate(voice)])

    try await backend.completeNext()
    try await expectOperation(.release(voice), at: 1, backend: backend)
    #expect(await backend.operations == [.activate(voice), .release(voice)])
    try await backend.completeNext()
    try await expectOperation(.activate(call), at: 2, backend: backend)
    try await backend.completeNext()
    try await expectOperation(.speaker(false, call), at: 3, backend: backend)
    try await backend.completeNext()
    try await finishOperation(gridStart, backend: backend)
    await #expect(throws: CancellationError.self) { try await finishOperation(voiceStart, backend: backend) }
    #expect(session.owns(call))
    #expect(session.release(voice) == nil)
    try await retireGrid(session, backend: backend, epoch: 2)
  }

  @Test("withdrawal cancels queued Grid activation before it can touch native audio")
  func withdrawalBeforeActivation() async throws {
    let backend = GridSessionTestBackend()
    let session = InlineAudioSession(backend: backend)
    defer { Task { await backend.drain() } }
    let voice = try session.acquire(.voice)
    session.willAcquire = { owner in
      if owner == .call {
        session.release(voice)
      }
    }
    let voiceStart = try await beginOperation {
      try await session.activate(voice, configuration: .voicePlayback)
    }
    try await expectOperation(.activate(voice), at: 0, backend: backend)
    let gridStart = try await beginOperation {
      try await session.setGridDemandActive(true, epoch: 1)
    }
    let call = try #require(session.current)
    try await session.setGridDemandActive(false, epoch: 2)
    await session.gridMediaDidQuiesce(epoch: 2)
    await session.observeGridDirections(
      recording: false,
      playing: false,
      nativeOperationsQuiescent: true,
      epoch: 2
    )
    #expect(session.owns(call))

    try await backend.completeNext()
    try await expectOperation(.release(voice), at: 1, backend: backend)
    try await backend.completeNext()
    try await expectOperation(.release(call), at: 2, backend: backend)
    try await backend.completeNext()
    await #expect(throws: CancellationError.self) { try await finishOperation(voiceStart, backend: backend) }
    await #expect(throws: CancellationError.self) { try await finishOperation(gridStart, backend: backend) }
    #expect(session.current == nil)
    #expect(await backend.operations == [.activate(voice), .release(voice), .release(call)])
  }

  @Test(
    "generic release cannot bypass matching provider and native idle receipts",
    arguments: [false, true]
  )
  func callReleaseNeedsBothReceipts(providerFirst: Bool) async throws {
    let backend = GridSessionTestBackend()
    let session = InlineAudioSession(backend: backend)
    defer { Task { await backend.drain() } }
    let call = try await startGrid(session, backend: backend)
    #expect(session.release(call) == nil)
    try await session.setGridDemandActive(false, epoch: 2)
    #expect(session.release(call) == nil)
    let operationCount = await backend.operations.count

    if providerFirst {
      await session.gridMediaDidQuiesce(epoch: 2)
      await session.observeGridDirections(
        recording: false,
        playing: false,
        nativeOperationsQuiescent: true,
        epoch: 1
      )
      await session.observeGridDirections(
        recording: false,
        playing: false,
        nativeOperationsQuiescent: false,
        epoch: 2
      )
      await session.observeGridDirections(
        recording: true,
        playing: false,
        nativeOperationsQuiescent: true,
        epoch: 2
      )
      await session.observeGridDirections(
        recording: false,
        playing: true,
        nativeOperationsQuiescent: true,
        epoch: 2
      )
    } else {
      await session.observeGridDirections(
        recording: false,
        playing: false,
        nativeOperationsQuiescent: true,
        epoch: 2
      )
      await session.gridMediaDidQuiesce(epoch: 1)
    }
    #expect(session.owns(call))
    #expect(await backend.operations.count == operationCount)

    let retirement = try await beginOperation {
      if providerFirst {
        await session.observeGridDirections(
          recording: false,
          playing: false,
          nativeOperationsQuiescent: true,
          epoch: 2
        )
      } else {
        await session.gridMediaDidQuiesce(epoch: 2)
      }
    }
    try await expectOperation(.release(call), at: operationCount, backend: backend)
    #expect(session.owns(call))
    try await backend.completeNext()
    try await finishOperation(retirement, backend: backend)
    #expect(session.current == nil)
    #expect(!session.isGridActive)
  }

  @Test(
    "a delayed or failed call teardown cannot admit an ordinary successor",
    arguments: [false, true]
  )
  func retirementBlocksSuccessor(releaseFails: Bool) async throws {
    let backend = GridSessionTestBackend()
    let session = InlineAudioSession(backend: backend)
    defer { Task { await backend.drain() } }
    let call = try await startGrid(session, backend: backend)
    try await session.setGridDemandActive(false, epoch: 2)
    await session.gridMediaDidQuiesce(epoch: 2)
    let index = await backend.operations.count
    let retirement = try await beginOperation {
      await session.observeGridDirections(
        recording: false,
        playing: false,
        nativeOperationsQuiescent: true,
        epoch: 2
      )
    }
    try await expectOperation(.release(call), at: index, backend: backend)
    for owner in [InlineAudioSession.Owner.voice, .recording, .draftPreview, .video] {
      #expect(throws: AudioPlaybackError.self) { try session.acquire(owner) }
    }
    #expect(session.owns(call))
    try await backend.completeNext(failing: releaseFails)
    try await finishOperation(retirement, backend: backend)

    if releaseFails {
      #expect(session.isQuarantined)
      #expect(session.voiceDenial?.localizedDescription == InlineAudioSessionError.quarantined.localizedDescription)
      #expect(session.owns(call))
      #expect(throws: InlineAudioSessionError.self) { try session.acquire(.voice) }
      #expect(throws: InlineAudioSessionError.self) { try session.acquire(.recording) }
      #expect(await backend.operations.count == index + 1)
    } else {
      #expect(!session.isQuarantined)
      #expect(session.current == nil)
      try await exerciseOrdinarySuccessor(session, backend: backend)
    }
  }

  @Test("failed activation and failed cleanup retain the call reservation")
  func activationFailureWithFailedCleanup() async throws {
    let backend = GridSessionTestBackend()
    let session = InlineAudioSession(backend: backend)
    defer { Task { await backend.drain() } }
    let start = try await beginOperation { try await session.setGridDemandActive(true, epoch: 1) }
    let call = try #require(session.current)
    try await expectOperation(.activate(call), at: 0, backend: backend)
    // A native activation error can include failed cleanup of partially owned
    // hardware. It is not evidence that the call's obligation is already idle.
    try await backend.completeNext(failing: true)
    await #expect(throws: (any Error).self) { try await finishOperation(start, backend: backend) }
    #expect(session.owns(call))
    #expect(!session.isQuarantined)
    #expect(session.release(call) == nil)
    #expect(throws: AudioPlaybackError.self) { try session.acquire(.voice) }
    #expect(throws: AudioPlaybackError.self) { try session.acquire(.recording) }
    #expect(await backend.operations == [.activate(call)])

    try await session.setGridDemandActive(false, epoch: 2)
    await session.gridMediaDidQuiesce(epoch: 2)
    let cleanup = try await beginOperation {
      await session.observeGridDirections(
        recording: false,
        playing: false,
        nativeOperationsQuiescent: true,
        epoch: 2
      )
    }
    try await expectOperation(.release(call), at: 1, backend: backend)
    try await backend.completeNext(failing: true)
    try await finishOperation(cleanup, backend: backend)
    #expect(session.isQuarantined)
    #expect(session.owns(call))
    #expect(session.release(call) == nil)
    #expect(session.voiceDenial?.localizedDescription == InlineAudioSessionError.quarantined.localizedDescription)
    #expect(throws: InlineAudioSessionError.self) { try session.acquire(.voice) }
    #expect(throws: InlineAudioSessionError.self) { try session.validateGridAdmission() }
    #expect(await backend.operations == [.activate(call), .release(call)])
  }

  @Test("initial route failure requires complete activation and routing on same-epoch retry")
  func routeFailureRetriesActivation() async throws {
    let backend = GridSessionTestBackend()
    let session = InlineAudioSession(backend: backend)
    defer { Task { await backend.drain() } }
    let firstStart = try await beginOperation {
      try await session.setGridDemandActive(true, epoch: 1)
    }
    let call = try #require(session.current)
    try await expectOperation(.activate(call), at: 0, backend: backend)
    try await backend.completeNext()
    try await expectOperation(.speaker(false, call), at: 1, backend: backend)
    try await backend.completeNext(failing: true)
    await #expect(throws: (any Error).self) { try await finishOperation(firstStart, backend: backend) }
    #expect(session.owns(call))
    #expect(!session.isQuarantined)

    let retry = try await beginOperation {
      try await session.setGridDemandActive(true, epoch: 1)
    }
    try await expectOperation(.activate(call), at: 2, backend: backend)
    try await backend.completeNext()
    try await expectOperation(.speaker(false, call), at: 3, backend: backend)
    try await backend.completeNext()
    try await finishOperation(retry, backend: backend)
    #expect(session.owns(call))
    #expect(await backend.operations == [
      .activate(call),
      .speaker(false, call),
      .activate(call),
      .speaker(false, call),
    ])
    try await retireGrid(session, backend: backend, epoch: 2)
  }

  @Test(
    "voice and Grid reset notification order cannot revoke an unretired call",
    arguments: [false, true]
  )
  func resetRetainsCall(gridNotificationFirst: Bool) async throws {
    let backend = GridSessionTestBackend()
    let session = InlineAudioSession(backend: backend)
    defer { Task { await backend.drain() } }
    let call = try await startGrid(session, backend: backend)
    let operationCount = await backend.operations.count
    if gridNotificationFirst {
      session.quarantineAfterMediaServicesReset()
      session.invalidate()
    } else {
      session.invalidate()
      session.quarantineAfterMediaServicesReset()
    }
    #expect(session.isQuarantined)
    #expect(session.owns(call))
    #expect(session.release(call) == nil)
    #expect(throws: InlineAudioSessionError.self) { try session.acquire(.voice) }
    #expect(throws: InlineAudioSessionError.self) { try session.acquire(.recording) }
    try await session.setGridDemandActive(false, epoch: 2)
    await session.gridMediaDidQuiesce(epoch: 2)
    await session.observeGridDirections(
      recording: false,
      playing: false,
      nativeOperationsQuiescent: true,
      epoch: 2
    )
    await #expect(throws: InlineAudioSessionError.self) {
      try await session.resumeGridSession(epoch: 2)
    }
    #expect(session.owns(call))
    #expect(await backend.operations.count == operationCount)
  }

  @Test(
    "reset after Grid retirement preserves ordinary invalidation and ordered recovery",
    arguments: [false, true]
  )
  func resetAfterRetirement(gridNotificationFirst: Bool) async throws {
    let backend = GridSessionTestBackend()
    let session = InlineAudioSession(backend: backend)
    defer { Task { await backend.drain() } }
    _ = try await startGrid(session, backend: backend)
    try await retireGrid(session, backend: backend, epoch: 2)
    let voice = try session.acquire(.voice)
    let index = await backend.operations.count
    let voiceStart = try await beginOperation {
      try await session.activate(voice, configuration: .voicePlayback)
    }
    try await expectOperation(.activate(voice), at: index, backend: backend)
    if gridNotificationFirst {
      session.quarantineAfterMediaServicesReset()
      session.invalidate()
    } else {
      session.invalidate()
      session.quarantineAfterMediaServicesReset()
    }
    #expect(!session.isQuarantined)
    #expect(session.current == nil)
    #expect(throws: InlineAudioSessionError.self) { try session.validateGridAdmission() }
    let successor = try session.acquire(.video)
    let successorStart = try await beginOperation {
      try await session.activate(successor, configuration: .voicePlayback)
    }
    #expect(await backend.operations.count == index + 1)

    try await backend.completeNext()
    try await expectOperation(.invalidate, at: index + 1, backend: backend)
    #expect(session.owns(successor))
    try await backend.completeNext()
    try await expectOperation(.activate(successor), at: index + 2, backend: backend)
    try await backend.completeNext()
    try await finishOperation(successorStart, backend: backend)
    await #expect(throws: CancellationError.self) { try await finishOperation(voiceStart, backend: backend) }
    #expect(session.owns(successor))
    let release = try #require(session.release(successor))
    try await expectOperation(.release(successor), at: index + 3, backend: backend)
    try await backend.completeNext()
    try await finishOperation(release, backend: backend)
  }

  @Test(
    "queued speaker and recovery work from a withdrawn epoch cannot reach a successor",
    arguments: [QueuedGridOperation.speaker, .recovery]
  )
  func staleGridOperation(operation: QueuedGridOperation) async throws {
    let backend = GridSessionTestBackend()
    let session = InlineAudioSession(backend: backend)
    defer { Task { await backend.drain() } }
    let call = try await startGrid(session, backend: backend)
    let index = await backend.operations.count
    let blockedSpeaker = try await beginOperation { try await session.setSpeakerPreferred(true) }
    try await expectOperation(.speaker(true, call), at: index, backend: backend)
    let stale = try await beginOperation {
      switch operation {
        case .speaker: try await session.setSpeakerPreferred(false)
        case .recovery: try await session.resumeGridSession(epoch: 1)
      }
    }
    let replacement = try await beginOperation {
      try await session.setGridDemandActive(true, epoch: 2)
    }
    #expect(session.owns(call))
    #expect(await backend.operations.count == index + 1)

    try await backend.completeNext()
    // After the controlled boundary, allow any unexpected I/O to finish and
    // remain in the trace: a regression should fail an assertion, not hang.
    await backend.drain()
    await #expect(throws: CancellationError.self) { try await finishOperation(blockedSpeaker, backend: backend) }
    await #expect(throws: CancellationError.self) { try await finishOperation(stale, backend: backend) }
    try await finishOperation(replacement, backend: backend)
    // Reapplying the admitted replacement must still reuse native activation.
    // A stale recovery catch must not clear its active state after it completes.
    try await session.setGridDemandActive(true, epoch: 2)
    #expect(await backend.operations == [.activate(call), .speaker(false, call), .speaker(true, call)])
    #expect(!session.isSpeakerPreferred)
    try await session.setGridDemandActive(false, epoch: 3)
    await session.gridMediaDidQuiesce(epoch: 3)
    await session.observeGridDirections(
      recording: false,
      playing: false,
      nativeOperationsQuiescent: true,
      epoch: 3
    )
    #expect(session.current == nil)
    let successor = try session.acquire(.video)
    try await session.activate(successor, configuration: .voicePlayback)
    let finalOperationCount = await backend.operations.count
    await #expect(throws: InlineAudioSessionError.self) {
      try await session.resumeGridSession(epoch: 1)
    }
    await #expect(throws: InlineAudioSessionError.self) {
      try await session.setSpeakerPreferred(true)
    }
    #expect(await backend.operations.count == finalOperationCount)
    #expect(session.owns(successor))
    let release = try #require(session.release(successor))
    try await finishOperation(release, backend: backend)
  }

  enum QueuedGridOperation: Sendable { case speaker, recovery }
}

@MainActor
private func beginOperation(
  _ operation: @escaping @MainActor () async throws -> Void
) async throws -> Task<Void, Error> {
  let started = AsyncStream.makeStream(of: Bool.self)
  let task = Task { @MainActor in
    started.continuation.yield(true)
    started.continuation.finish()
    try await operation()
  }
  var iterator = started.stream.makeAsyncIterator()
  // Both tasks run on MainActor: observing this signal means operation reached
  // its first suspension (or completed), rather than relying on Task.yield.
  try #require(await iterator.next() == true)
  return task
}

@MainActor
private func startGrid(
  _ session: InlineAudioSession, backend: GridSessionTestBackend
) async throws -> InlineAudioSession.Token {
  let index = await backend.operations.count
  let start = try await beginOperation { try await session.setGridDemandActive(true, epoch: 1) }
  let token = try #require(session.current)
  #expect(token.owner == .call)
  try await expectOperation(.activate(token), at: index, backend: backend)
  try await backend.completeNext()
  try await expectOperation(.speaker(false, token), at: index + 1, backend: backend)
  try await backend.completeNext()
  try await finishOperation(start, backend: backend)
  return token
}

@MainActor
private func retireGrid(
  _ session: InlineAudioSession, backend: GridSessionTestBackend, epoch: UInt64
) async throws {
  let token = try #require(session.current)
  let index = await backend.operations.count
  try await session.setGridDemandActive(false, epoch: epoch)
  await session.gridMediaDidQuiesce(epoch: epoch)
  let retirement = try await beginOperation {
    await session.observeGridDirections(
      recording: false,
      playing: false,
      nativeOperationsQuiescent: true,
      epoch: epoch
    )
  }
  try await expectOperation(.release(token), at: index, backend: backend)
  try await backend.completeNext()
  try await finishOperation(retirement, backend: backend)
  #expect(session.current == nil)
}

@MainActor
private func exerciseOrdinarySuccessor(
  _ session: InlineAudioSession, backend: GridSessionTestBackend
) async throws {
  let token = try session.acquire(.video)
  let index = await backend.operations.count
  let start = try await beginOperation {
    try await session.activate(token, configuration: .voicePlayback)
  }
  try await expectOperation(.activate(token), at: index, backend: backend)
  try await backend.completeNext()
  try await finishOperation(start, backend: backend)
  #expect(session.owns(token))
  let release = try #require(session.release(token))
  try await expectOperation(.release(token), at: index + 1, backend: backend)
  try await backend.completeNext()
  try await finishOperation(release, backend: backend)
}

@MainActor
private func finishOperation(
  _ task: Task<Void, Error>, backend: GridSessionTestBackend
) async throws {
  try await withTaskCancellationHandler {
    try await task.value
    try Task.checkCancellation()
  } onCancel: {
    task.cancel()
    Task { await backend.drain() }
  }
}

private func expectOperation(
  _ expected: GridSessionTestBackend.Operation, at index: Int, backend: GridSessionTestBackend
) async throws {
  let actual = await backend.operation(at: index)
  try #require(actual == expected)
}

/// Every native boundary is explicitly released by its test. The production
/// InlineAudioSession FIFO is exercised unchanged; no AVAudioSession writes occur.
private actor GridSessionTestBackend: InlineAudioSessionBackend {
  enum Operation: Equatable, Sendable {
    case activate(InlineAudioSession.Token)
    case release(InlineAudioSession.Token)
    case speaker(Bool, InlineAudioSession.Token)
    case invalidate
    case drained
  }

  private enum Failure: Error { case missingOperation, nativeFailure }
  private var pending: [CheckedContinuation<Void, Error>] = []
  private var observers: [Int: [UUID: CheckedContinuation<Operation, Never>]] = [:]
  private var isDraining = false
  private(set) var operations: [Operation] = []

  func activate(token: InlineAudioSession.Token, configuration _: InlineAudioSession.Configuration) async throws {
    try await suspend(.activate(token))
  }

  func release(token: InlineAudioSession.Token) async throws {
    try await suspend(.release(token))
  }

  func setSpeakerPreferred(_ preferred: Bool, token: InlineAudioSession.Token) async throws {
    try await suspend(.speaker(preferred, token))
  }

  func invalidate() async {
    try? await suspend(.invalidate)
  }

  func operation(at index: Int) async -> Operation {
    let id = UUID()
    return await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        if isDraining || Task.isCancelled {
          continuation.resume(returning: .drained)
        } else if index < operations.count {
          continuation.resume(returning: operations[index])
        } else {
          observers[index, default: [:]][id] = continuation
        }
      }
    } onCancel: {
      Task { await self.cancelObservation(at: index, id: id) }
    }
  }

  func completeNext(failing: Bool = false) throws {
    guard !pending.isEmpty else { throw Failure.missingOperation }
    let continuation = pending.removeFirst()
    if failing {
      continuation.resume(throwing: Failure.nativeFailure)
    } else {
      continuation.resume()
    }
  }

  func drain() {
    isDraining = true
    let continuations = pending
    pending.removeAll()
    for continuation in continuations {
      continuation.resume()
    }
    let waiting = observers.values.flatMap { Array($0.values) }
    observers.removeAll()
    for observer in waiting {
      observer.resume(returning: .drained)
    }
  }

  private func suspend(_ operation: Operation) async throws {
    let index = operations.count
    operations.append(operation)
    for observer in (observers.removeValue(forKey: index) ?? [:]).values {
      observer.resume(returning: operation)
    }
    guard !isDraining else { return }
    try await withCheckedThrowingContinuation { pending.append($0) }
  }

  private func cancelObservation(at index: Int, id: UUID) {
    observers[index]?.removeValue(forKey: id)?.resume(returning: .drained)
    if observers[index]?.isEmpty == true {
      observers[index] = nil
    }
  }
}
