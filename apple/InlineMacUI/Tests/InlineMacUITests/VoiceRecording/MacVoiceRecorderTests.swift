import Foundation
import Testing
@testable import InlineMacUI

@Suite("Mac voice recorder", .serialized)
struct MacVoiceRecorderTests {
  @Test("construction is inert until a user starts recording")
  func constructionIsInertUntilStart() async throws {
    let probe = RecorderProbe()
    let recorder = makeRecorder(probe: probe)

    #expect(probe.events == [])

    let session = try await recorder.start()

    #expect(probe.events == [.make, .prepare, .record])
    await session.cancel()
    #expect(probe.events == [.make, .prepare, .record, .stop])
  }

  @Test("one process owner rejects a competing recording")
  func rejectsCompetingRecording() async throws {
    let probe = RecorderProbe()
    let recorder = makeRecorder(probe: probe)
    let session = try await recorder.start()

    await #expect(throws: MacVoiceRecorderError.busy) {
      _ = try await recorder.start()
    }

    await session.cancel()
  }

  @Test("finish stops capture before processing")
  func finishStopsBeforeProcessing() async throws {
    let probe = RecorderProbe()
    let recorder = makeRecorder(probe: probe)
    let session = try await recorder.start()

    let recording = try await session.finish()

    #expect(recording.data == Data("voice".utf8))
    #expect(probe.events == [.make, .prepare, .record, .stop, .process])
  }

  @Test("failed starts do not leave an active owner")
  func failedStartReleasesOwner() async throws {
    let probe = RecorderProbe(recordAccepted: false)
    let recorder = makeRecorder(probe: probe)

    await #expect(throws: MacVoiceRecorderError.startFailed) {
      _ = try await recorder.start()
    }
    await #expect(throws: MacVoiceRecorderError.startFailed) {
      _ = try await recorder.start()
    }

    #expect(
      probe.events == [
        .make, .prepare, .record, .stop,
        .make, .prepare, .record, .stop,
      ]
    )
  }

  @Test("offline processing does not block the next recording", .timeLimit(.minutes(1)))
  func processingDoesNotBlockNextRecording() async throws {
    let probe = RecorderProbe()
    let gate = ProcessingGate()
    let recorder = MacVoiceRecorder(
      makeBackend: { _, _ in
        probe.append(.make)
        return TestRecordingBackend(probe: probe)
      },
      processCapture: { capture in
        probe.append(.process)
        gate.blockProcessing()
        return makeTestRecording(from: capture)
      }
    )
    let firstSession = try await recorder.start()
    let finishTask = Task {
      try await firstSession.finish()
    }

    await gate.waitUntilStarted()
    let watchdog = Task {
      try? await Task.sleep(nanoseconds: 2_000_000_000)
      gate.release()
    }
    let secondSession = try await recorder.start()

    #expect(!gate.wasReleased)
    await secondSession.cancel()
    gate.release()
    watchdog.cancel()
    _ = try await finishTask.value
  }

  private func makeRecorder(probe: RecorderProbe) -> MacVoiceRecorder {
    MacVoiceRecorder(
      makeBackend: { _, _ in
        probe.append(.make)
        return TestRecordingBackend(probe: probe)
      },
      processCapture: { capture in
        probe.append(.process)
        return makeTestRecording(from: capture)
      }
    )
  }
}

private func makeTestRecording(from capture: MacVoiceCaptureOutput) -> MacVoiceRecording {
  MacVoiceRecording(
    fileURL: capture.finalURL,
    data: Data("voice".utf8),
    duration: capture.duration,
    waveform: Data([1, 2, 3]),
    mimeType: "audio/mp4",
    fileExtension: "m4a"
  )
}

private final class ProcessingGate: @unchecked Sendable {
  private let lock = NSLock()
  private let releaseSemaphore = DispatchSemaphore(value: 0)
  private var started = false
  private var released = false
  private var startContinuation: CheckedContinuation<Void, Never>?

  var wasReleased: Bool {
    lock.lock()
    defer { lock.unlock() }
    return released
  }

  func waitUntilStarted() async {
    await withCheckedContinuation { continuation in
      lock.lock()
      if started {
        lock.unlock()
        continuation.resume()
      } else {
        startContinuation = continuation
        lock.unlock()
      }
    }
  }

  func blockProcessing() {
    lock.lock()
    started = true
    let continuation = startContinuation
    startContinuation = nil
    lock.unlock()
    continuation?.resume()
    releaseSemaphore.wait()
  }

  func release() {
    lock.lock()
    guard !released else {
      lock.unlock()
      return
    }
    released = true
    lock.unlock()
    releaseSemaphore.signal()
  }
}

private final class RecorderProbe: @unchecked Sendable {
  enum Event: Equatable {
    case make
    case prepare
    case record
    case stop
    case process
  }

  private let lock = NSLock()
  private var storedEvents: [Event] = []
  let recordAccepted: Bool

  init(recordAccepted: Bool = true) {
    self.recordAccepted = recordAccepted
  }

  var events: [Event] {
    lock.lock()
    defer { lock.unlock() }
    return storedEvents
  }

  func append(_ event: Event) {
    lock.lock()
    storedEvents.append(event)
    lock.unlock()
  }
}

private final class TestRecordingBackend: MacVoiceRecordingBackend {
  private let probe: RecorderProbe
  private(set) var isRecording = false
  var currentTime: TimeInterval { isRecording ? 0.05 : 0 }
  var isMeteringEnabled = false

  init(probe: RecorderProbe) {
    self.probe = probe
  }

  func prepareToRecord() -> Bool {
    probe.append(.prepare)
    return true
  }

  func record() -> Bool {
    probe.append(.record)
    isRecording = probe.recordAccepted
    return probe.recordAccepted
  }

  func stop() {
    probe.append(.stop)
    isRecording = false
  }

  func updateMeters() {}

  func averagePower(forChannel _: Int) -> Float {
    -12
  }
}
