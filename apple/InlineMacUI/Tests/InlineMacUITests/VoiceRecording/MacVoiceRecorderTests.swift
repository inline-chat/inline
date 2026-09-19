import AVFoundation
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
    #expect(probe.maximumDuration == nil)
  }

  @Test("a native duration stop preserves dictation until its owner finalizes it", .timeLimit(.minutes(1)))
  func durationLimitPreservesRecording() async throws {
    let probe = RecorderProbe()
    let backend = TestRecordingBackend(probe: probe)
    let recorder = makeRecorder(probe: probe, backend: backend)
    let session = try await recorder.start(maximumDuration: 600)
    #expect(probe.maximumDuration == 600)

    backend.terminate(.finishedSuccessfully)
    var lastUpdate: MacVoiceRecordingUpdate?
    for try await update in session.updates { lastUpdate = update }
    #expect(lastUpdate?.reachedDurationLimit == true)
    #expect(lastUpdate?.duration == 600)
    #expect(!probe.events.contains(.process))

    let recording = try await session.finish()
    #expect(recording.data == Data("voice".utf8))
    #expect(probe.events == [.make, .prepare, .record, .stop, .process])
  }

  @Test("the capture queue enforces the bound even before a native completion callback", .timeLimit(.minutes(1)))
  func meteringLimitPreservesRecording() async throws {
    let probe = RecorderProbe()
    let backend = TestRecordingBackend(probe: probe)
    let recorder = makeRecorder(probe: probe, backend: backend)
    let session = try await recorder.start(maximumDuration: 600)
    backend.setCurrentTime(601)
    var reachedLimit = false
    for try await update in session.updates { reachedLimit = update.reachedDurationLimit }
    #expect(reachedLimit)
    #expect(try await session.finish().data == Data("voice".utf8))
  }

  @Test("a native stop before its delegate callback survives a delayed start return", .timeLimit(.minutes(1)))
  func nativeStopBeforeDelegatePreservesRecording() async throws {
    let probe = RecorderProbe()
    let backend = TestRecordingBackend(probe: probe, startDelay: 0.25)
    let recorder = makeRecorder(probe: probe, backend: backend)
    let session = try await recorder.start(maximumDuration: 0.2)
    backend.stopWithoutDelegateCallback()
    var reachedLimit = false
    for try await update in session.updates { reachedLimit = update.reachedDurationLimit }
    #expect(reachedLimit)
    #expect(try await session.finish().data == Data("voice".utf8))
  }

  @Test("an automatically stopped recording can be cancelled without blocking the next start", .timeLimit(.minutes(1)))
  func cancelAfterDurationLimit() async throws {
    let probe = RecorderProbe()
    let backend = TestRecordingBackend(probe: probe)
    let recorder = makeRecorder(probe: probe, backend: backend)
    let session = try await recorder.start(maximumDuration: 600)
    backend.terminate(.finishedSuccessfully)
    for try await _ in session.updates {}
    await session.cancel()
    await #expect(throws: MacVoiceRecorderError.sessionEnded) { _ = try await session.finish() }
    let nextSession = try await recorder.start()
    await nextSession.cancel()
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
      processCapture: { capture, cancellation in
        probe.append(.process)
        gate.blockProcessing()
        try cancellation.checkCancellation()
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

  @Test("discard cancels processing, removes temporary files, and permits the next start", .timeLimit(.minutes(1)))
  func discardDuringProcessingCleansUpAndPermitsNextStart() async throws {
    let probe = RecorderProbe()
    let gate = ProcessingGate()
    let outputProbe = CaptureOutputProbe()
    let recorder = MacVoiceRecorder(
      makeBackend: { _, _ in
        probe.append(.make)
        return TestRecordingBackend(probe: probe)
      },
      processCapture: { capture, cancellation in
        try Data("raw".utf8).write(to: capture.rawURL)
        try Data("final".utf8).write(to: capture.finalURL)
        outputProbe.capture(capture)
        gate.blockProcessing()
        try cancellation.checkCancellation()
        return makeTestRecording(from: capture)
      }
    )
    let firstSession = try await recorder.start()
    let finishTask = Task {
      try await firstSession.finish()
    }

    await gate.waitUntilStarted()
    defer { gate.release() }
    let output = try #require(outputProbe.output)

    await firstSession.cancel()

    #expect(!FileManager.default.fileExists(atPath: output.rawURL.path))
    #expect(!FileManager.default.fileExists(atPath: output.finalURL.path))

    let secondSession = try await recorder.start()
    await secondSession.cancel()

    gate.release()
    await #expect(throws: CancellationError.self) {
      _ = try await finishTask.value
    }
  }

  @Test("input loss terminates the stream and releases the recorder", .timeLimit(.minutes(1)))
  func inputLossTerminatesAndPermitsRecovery() async throws {
    let probe = RecorderProbe()
    let backend = TestRecordingBackend(probe: probe)
    let recorder = makeRecorder(probe: probe, backend: backend)
    let session = try await recorder.start()
    let updatesTask = consume(session.updates)

    backend.stopWithoutDelegateCallback()

    await #expect(throws: MacVoiceRecorderError.recordingInterrupted) {
      try await updatesTask.value
    }
    let recoveredSession = try await recorder.start()
    await recoveredSession.cancel()
  }

  @Test("encoder failure terminates the stream and releases the recorder", .timeLimit(.minutes(1)))
  func encoderFailureTerminatesAndPermitsRecovery() async throws {
    let probe = RecorderProbe()
    let backend = TestRecordingBackend(probe: probe)
    let recorder = makeRecorder(probe: probe, backend: backend)
    let session = try await recorder.start()
    let updatesTask = consume(session.updates)

    backend.terminate(.encodingFailed)

    await #expect(throws: MacVoiceRecorderError.encodingFailed) {
      try await updatesTask.value
    }
    let recoveredSession = try await recorder.start()
    await recoveredSession.cancel()
  }

  @Test("processor converts a CAF fixture to decodable AAC and cleans the raw file")
  func processorConvertsCAFFixture() throws {
    let fixtureDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("inline-voice-processor-fixture-\(UUID().uuidString)")
    let rawURL = fixtureDirectory.appendingPathComponent("input.caf")
    let finalURL = fixtureDirectory.appendingPathComponent("output.m4a")
    try FileManager.default.createDirectory(
      at: fixtureDirectory,
      withIntermediateDirectories: true
    )
    defer {
      try? FileManager.default.removeItem(at: rawURL)
      try? FileManager.default.removeItem(at: finalURL)
      try? FileManager.default.removeItem(at: fixtureDirectory)
    }
    try writeCAFFixture(to: rawURL)

    let recording = try MacVoiceRecordingProcessor.process(
      MacVoiceCaptureOutput(
        rawURL: rawURL,
        finalURL: finalURL,
        duration: 0.1,
        samples: [12, 48, 96, 160]
      ),
      cancellation: MacVoiceProcessingCancellation()
    )

    #expect(!recording.data.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: rawURL.path))
    #expect(FileManager.default.fileExists(atPath: finalURL.path))
    let decoded = try AVAudioFile(forReading: finalURL)
    #expect(decoded.length > 0)
    #expect(decoded.processingFormat.channelCount == 1)
  }

  @Test("bounded dictation crops actual audio to ten minutes within the four MiB upload budget", .timeLimit(.minutes(1)))
  func processorBoundsActualAudio() throws {
    let fixtureDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("inline-dictation-limit-fixture-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: fixtureDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: fixtureDirectory) }
    let rawURL = fixtureDirectory.appendingPathComponent("input.caf")
    let finalURL = fixtureDirectory.appendingPathComponent("output.m4a")
    try writeCAFFixture(to: rawURL, duration: 600.25)

    let recording = try MacVoiceRecordingProcessor.process(
      MacVoiceCaptureOutput(
        rawURL: rawURL, finalURL: finalURL, duration: 605, samples: [12, 48, 96, 160], maximumDuration: 600
      ),
      cancellation: MacVoiceProcessingCancellation()
    )

    let decoded = try AVAudioFile(forReading: finalURL)
    let decodedDuration = Double(decoded.length) / decoded.processingFormat.sampleRate
    #expect(decodedDuration <= 600)
    #expect(decodedDuration >= 599.9)
    #expect(recording.duration == 600)
    #expect(recording.data.count <= 4 * 1024 * 1024)
    #expect(!FileManager.default.fileExists(atPath: rawURL.path))
  }

  private func makeRecorder(
    probe: RecorderProbe,
    backend: TestRecordingBackend? = nil
  ) -> MacVoiceRecorder {
    MacVoiceRecorder(
      makeBackend: { _, _ in
        probe.append(.make)
        return backend ?? TestRecordingBackend(probe: probe)
      },
      processCapture: { capture, _ in
        probe.append(.process)
        return makeTestRecording(from: capture)
      }
    )
  }
}

private func consume(
  _ updates: AsyncThrowingStream<MacVoiceRecordingUpdate, any Error>
) -> Task<Void, any Error> {
  Task {
    for try await _ in updates {}
  }
}

private func writeCAFFixture(to url: URL, duration: TimeInterval = 0.1) throws {
  let sampleRate = 48_000.0
  let frameCount = Int(sampleRate * duration)
  let capacity = AVAudioFrameCount(min(frameCount, 8_192))
  let format = try #require(
    AVAudioFormat(
      commonFormat: .pcmFormatFloat32,
      sampleRate: sampleRate,
      channels: 2,
      interleaved: false
    )
  )
  let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity))
  let channels = try #require(buffer.floatChannelData)
  let file = try AVAudioFile(forWriting: url, settings: format.settings)
  for offset in stride(from: 0, to: frameCount, by: Int(capacity)) {
    buffer.frameLength = AVAudioFrameCount(min(Int(capacity), frameCount - offset))
    for frame in 0 ..< Int(buffer.frameLength) {
      let time = Double(offset + frame) / sampleRate
      channels[0][frame] = Float(sin(2 * .pi * 440 * time) * 0.2)
      channels[1][frame] = Float(sin(2 * .pi * 660 * time) * 0.1)
    }
    try file.write(from: buffer)
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

private final class CaptureOutputProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var storedOutput: MacVoiceCaptureOutput?

  var output: MacVoiceCaptureOutput? {
    lock.lock()
    defer { lock.unlock() }
    return storedOutput
  }

  func capture(_ output: MacVoiceCaptureOutput) {
    lock.lock()
    storedOutput = output
    lock.unlock()
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
  private var storedMaximumDuration: TimeInterval?
  let recordAccepted: Bool

  init(recordAccepted: Bool = true) {
    self.recordAccepted = recordAccepted
  }

  var events: [Event] {
    lock.lock()
    defer { lock.unlock() }
    return storedEvents
  }

  var maximumDuration: TimeInterval? {
    get {
      lock.lock()
      defer { lock.unlock() }
      return storedMaximumDuration
    }
    set {
      lock.lock()
      storedMaximumDuration = newValue
      lock.unlock()
    }
  }

  func append(_ event: Event) {
    lock.lock()
    storedEvents.append(event)
    lock.unlock()
  }
}

private final class TestRecordingBackend: MacVoiceRecordingBackend, @unchecked Sendable {
  private let lock = NSLock()
  private let probe: RecorderProbe
  private let startDelay: TimeInterval
  private var recording = false
  private var recordedTime: TimeInterval = 0.05
  private var meteringEnabled = false
  private var storedTerminationHandler:
    (@Sendable (MacVoiceRecordingBackendTermination) -> Void)?

  var isRecording: Bool {
    lock.lock()
    defer { lock.unlock() }
    return recording
  }

  var currentTime: TimeInterval {
    lock.lock()
    defer { lock.unlock() }
    return recording ? recordedTime : 0
  }

  func setCurrentTime(_ time: TimeInterval) {
    lock.lock()
    recordedTime = time
    lock.unlock()
  }

  var isMeteringEnabled: Bool {
    get {
      lock.lock()
      defer { lock.unlock() }
      return meteringEnabled
    }
    set {
      lock.lock()
      meteringEnabled = newValue
      lock.unlock()
    }
  }

  var terminationHandler: (@Sendable (MacVoiceRecordingBackendTermination) -> Void)? {
    get {
      lock.lock()
      defer { lock.unlock() }
      return storedTerminationHandler
    }
    set {
      lock.lock()
      storedTerminationHandler = newValue
      lock.unlock()
    }
  }

  init(probe: RecorderProbe, startDelay: TimeInterval = 0) {
    self.probe = probe
    self.startDelay = startDelay
  }

  func prepareToRecord() -> Bool {
    probe.append(.prepare)
    return true
  }

  func record(forDuration duration: TimeInterval?) -> Bool {
    probe.append(.record)
    probe.maximumDuration = duration
    if startDelay > 0 { Thread.sleep(forTimeInterval: startDelay) }
    lock.lock()
    recording = probe.recordAccepted
    lock.unlock()
    return probe.recordAccepted
  }

  func stop() {
    probe.append(.stop)
    lock.lock()
    recording = false
    lock.unlock()
  }

  func updateMeters() {}

  func averagePower(forChannel _: Int) -> Float {
    -12
  }

  func stopWithoutDelegateCallback() {
    lock.lock()
    recording = false
    lock.unlock()
  }

  func terminate(_ termination: MacVoiceRecordingBackendTermination) {
    lock.lock()
    recording = false
    let handler = storedTerminationHandler
    lock.unlock()
    handler?(termination)
  }
}
