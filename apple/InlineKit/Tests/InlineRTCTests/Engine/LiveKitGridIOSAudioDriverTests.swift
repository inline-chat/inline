#if os(iOS)
import Foundation
import LiveKit
import Testing

@testable import InlineRTC

@Suite("iOS Grid audio safety", .serialized)
struct LiveKitGridIOSAudioDriverTests {
  @Test("an interruption fencing suspended preparation prevents its late input opening")
  func interruptionFencesSuspendedPreparation() async throws {
    let backend = BlockingIOSGridAudioBackend(blockPreparation: true)
    let driver = LiveKitGridIOSAudioDriver(testingBackend: backend)
    try await driver.setMediaDemandActive(true, epoch: 1)
    let preparation = Task { try await driver.setPrepared(true) }
    try await waitUntil { backend.hasBlockedOperation }

    await driver.interruptionBegan()
    backend.releaseBlockedOperation()
    do {
      try await preparation.value
      Issue.record("The interrupted preparation must be superseded")
    } catch {}
    #expect(backend.inputOpeningCount == 0)
    #expect(!backend.outputAvailable)

    await driver.interruptionEnded(shouldResume: true)
    #expect(backend.activationCount == 1)
    #expect(backend.outputAvailable)
    #expect(backend.inputOpeningCount == 0)
  }

  @Test("admission withdrawal prevents suspended preparation from reopening either direction")
  func withdrawalFencesSuspendedPreparation() async throws {
    let backend = BlockingIOSGridAudioBackend(blockPreparation: true)
    let driver = LiveKitGridIOSAudioDriver(testingBackend: backend)
    try await driver.setMediaDemandActive(true, epoch: 1)
    let preparation = Task { try await driver.setPrepared(true) }
    try await waitUntil { backend.hasBlockedOperation }

    try await driver.setMediaDemandActive(false, epoch: 2)
    backend.releaseBlockedOperation()
    do {
      try await preparation.value
      Issue.record("The withdrawn preparation must be superseded")
    } catch {}
    #expect(backend.inputOpeningCount == 0)
    #expect(!backend.outputAvailable)
    try await driver.resumeListeningAfterSafetyPause()
    #expect(!backend.outputAvailable)
  }

  @Test("explicit retry cannot resume listening while a system interruption is active")
  func retryCannotResumeAnActiveInterruption() async throws {
    let backend = BlockingIOSGridAudioBackend()
    let driver = LiveKitGridIOSAudioDriver(testingBackend: backend)
    try await driver.setMediaDemandActive(true, epoch: 1)
    await driver.interruptionBegan()
    do {
      try await driver.resumeListeningAfterSafetyPause()
      Issue.record("Retry must be rejected while interrupted")
    } catch {}
    #expect(!backend.outputAvailable)
    #expect(backend.inputOpeningCount == 0)

    await driver.interruptionEnded(shouldResume: false)
    #expect(!backend.outputAvailable)
    try await driver.resumeListeningAfterSafetyPause()
    #expect(backend.outputAvailable)
    #expect(backend.inputOpeningCount == 0)
  }

  @Test("an unplugged private output requires explicit retry even after another interruption ends")
  func privateOutputDoesNotAutomaticallyResume() async throws {
    let backend = BlockingIOSGridAudioBackend()
    let driver = LiveKitGridIOSAudioDriver(testingBackend: backend)
    try await driver.setMediaDemandActive(true, epoch: 1)
    await driver.pauseForSafety(requiresExplicitOutputResume: true)
    await driver.interruptionBegan()
    await driver.interruptionEnded(shouldResume: true)
    #expect(!backend.outputAvailable)
    try await driver.resumeListeningAfterSafetyPause()
    #expect(backend.outputAvailable)
    #expect(backend.inputOpeningCount == 0)
  }

  @Test("withdrawing admission during a suspended listening retry prevents late output reopening")
  func withdrawalFencesSuspendedListeningResume() async throws {
    let backend = BlockingIOSGridAudioBackend()
    let driver = LiveKitGridIOSAudioDriver(testingBackend: backend)
    try await driver.setMediaDemandActive(true, epoch: 1)
    await driver.pauseForSafety(requiresExplicitOutputResume: true)
    backend.blockNextStop()
    let retry = Task { try await driver.resumeListeningAfterSafetyPause() }
    try await waitUntil { backend.hasBlockedOperation }

    try await driver.setMediaDemandActive(false, epoch: 2)
    backend.releaseBlockedOperation()
    try await retry.value
    #expect(!backend.outputAvailable)
    #expect(backend.inputOpeningCount == 0)
  }

  @Test("an audio services reset keeps both directions closed until process restart")
  func resetDoesNotPromiseUnsupportedRecovery() async throws {
    let backend = BlockingIOSGridAudioBackend()
    let driver = LiveKitGridIOSAudioDriver(testingBackend: backend)
    try await driver.setMediaDemandActive(true, epoch: 1)
    await driver.mediaServicesWereReset()
    do {
      try await driver.resumeListeningAfterSafetyPause()
      Issue.record("A reset requires process restart")
    } catch {}
    #expect(!backend.outputAvailable)
    #expect(backend.activationCount == 0)
    #expect(backend.inputOpeningCount == 0)
  }

  @Test("an interruption during suspended recovery stop prevents its old capture restart")
  func interruptionFencesSuspendedRecovery() async throws {
    let backend = BlockingIOSGridAudioBackend()
    let driver = LiveKitGridIOSAudioDriver(testingBackend: backend)
    try await driver.setMediaDemandActive(true, epoch: 1)
    try await driver.setPrepared(true)
    let openings = backend.inputOpeningCount
    backend.blockNextStop()
    let recovery = Task { try await driver.recoverPreparedAudio(preserving: nil) }
    try await waitUntil { backend.hasBlockedOperation }

    await driver.interruptionBegan()
    backend.releaseBlockedOperation()
    do {
      try await recovery.value
      Issue.record("Interrupted recovery must be superseded")
    } catch {}
    #expect(backend.inputOpeningCount == openings)
    #expect(!backend.outputAvailable)
  }

  @Test("the process is quarantined before an audio reset waits for native warm teardown")
  func resetQuarantinesBeforeSuspendedStop() async throws {
    let backend = BlockingIOSGridAudioBackend()
    let driver = LiveKitGridIOSAudioDriver(testingBackend: backend)
    try await driver.setMediaDemandActive(true, epoch: 1)
    backend.blockNextStop()
    let reset = Task { await driver.mediaServicesWereReset() }
    try await waitUntil { backend.hasBlockedOperation }
    #expect(await backend.isQuarantined())
    do {
      try await driver.resumeListeningAfterSafetyPause()
      Issue.record("Retry must be fenced before reset teardown returns")
    } catch {}
    #expect(!backend.outputAvailable)
    backend.releaseBlockedOperation()
    await reset.value
  }

  @Test("a receipt from an older call epoch cannot release the current retired writer")
  func quiescenceReceiptMatchesRetiredEpoch() async throws {
    let backend = BlockingIOSGridAudioBackend()
    let driver = LiveKitGridIOSAudioDriver(testingBackend: backend)
    try await driver.setMediaDemandActive(true, epoch: 1)
    try await driver.setMediaDemandActive(false, epoch: 2)
    try await driver.setMediaDemandActive(true, epoch: 3)
    try await driver.setMediaDemandActive(false, epoch: 4)
    await driver.mediaDidQuiesce(epoch: 2)
    #expect(backend.quiescenceEpochs.isEmpty)
    await driver.mediaDidQuiesce(epoch: 4)
    #expect(backend.quiescenceEpochs == [4])
  }
}

/// A suspended SDK operation, not a model of the driver's epoch state.
private final class BlockingIOSGridAudioBackend: IOSGridAudioBackend, @unchecked Sendable {
  private let lock = NSLock()
  private var blocksPreparation: Bool
  private var blocksStop = false
  private var continuation: CheckedContinuation<Void, Never>?
  private var inputOpenings = 0
  private var output = false
  private var activations = 0
  private var quarantined = false
  private var reportedQuiescenceEpochs: [UInt64] = []

  init(blockPreparation: Bool = false) { blocksPreparation = blockPreparation }

  var hasBlockedOperation: Bool { lock.withLock { continuation != nil } }
  var inputOpeningCount: Int { lock.withLock { inputOpenings } }
  var outputAvailable: Bool { lock.withLock { output } }
  var activationCount: Int { lock.withLock { activations } }
  var quiescenceEpochs: [UInt64] { lock.withLock { reportedQuiescenceEpochs } }

  func setEngineAvailability(_ availability: AudioEngineAvailability) throws {
    lock.withLock {
      if availability.isInputAvailable { inputOpenings += 1 }
      output = availability.isOutputAvailable
    }
  }

  func setRecordingAlwaysPreparedMode(_ value: Bool, audioProcessingOptions _: AudioProcessingOptions?) async throws {
    let shouldBlock = lock.withLock {
      if value, blocksPreparation {
        blocksPreparation = false
        return true
      }
      if !value, blocksStop {
        blocksStop = false
        return true
      }
      return false
    }
    if shouldBlock {
      await withCheckedContinuation { continuation in
        lock.withLock { self.continuation = continuation }
      }
    }
  }

  func blockNextStop() { lock.withLock { blocksStop = true } }

  func releaseBlockedOperation() {
    let continuation = lock.withLock {
      let result = self.continuation
      self.continuation = nil
      return result
    }
    continuation?.resume()
  }

  func isQuarantined() async -> Bool { lock.withLock { quarantined } }
  func setGridDemandActive(_: Bool, epoch _: UInt64) async throws {}
  func gridMediaDidQuiesce(epoch: UInt64) async { lock.withLock { reportedQuiescenceEpochs.append(epoch) } }
  func resumeGridSession(epoch _: UInt64) async throws { lock.withLock { activations += 1 } }
  func quarantineAfterMediaServicesReset() async { lock.withLock { quarantined = true } }
}

private func waitUntil(_ condition: @Sendable () -> Bool) async throws {
  let clock = ContinuousClock()
  let deadline = clock.now.advanced(by: .seconds(2))
  while !condition() {
    if clock.now >= deadline { throw IOSAudioSafetyTestTimeout() }
    try await Task.sleep(for: .milliseconds(5))
  }
}

private struct IOSAudioSafetyTestTimeout: Error {}
#endif
