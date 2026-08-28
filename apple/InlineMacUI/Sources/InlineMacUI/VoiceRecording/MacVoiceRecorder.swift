@preconcurrency import AVFoundation
import Foundation
import OSLog
import os.signpost

public struct MacVoiceRecording: Sendable {
  public let fileURL: URL
  public let data: Data
  public let duration: TimeInterval
  public let waveform: Data
  public let mimeType: String
  public let fileExtension: String

  public init(
    fileURL: URL,
    data: Data,
    duration: TimeInterval,
    waveform: Data,
    mimeType: String,
    fileExtension: String
  ) {
    self.fileURL = fileURL
    self.data = data
    self.duration = duration
    self.waveform = waveform
    self.mimeType = mimeType
    self.fileExtension = fileExtension
  }
}

public struct MacVoiceRecordingUpdate: Equatable, Sendable {
  public let duration: TimeInterval
  public let samples: [UInt8]
}

public enum MacVoiceRecorderError: LocalizedError, Equatable {
  case busy
  case startFailed
  case sessionEnded
  case recordingInterrupted
  case encodingFailed
  case emptyRecording
  case unsupportedInputFormat
  case processingFailed

  public var errorDescription: String? {
    switch self {
    case .busy:
      "Another voice recording is already active."
    case .startFailed:
      "Could not start voice recording."
    case .sessionEnded:
      "The voice recording has already ended."
    case .recordingInterrupted:
      "Voice recording stopped unexpectedly."
    case .encodingFailed:
      "Voice recording failed while writing audio."
    case .emptyRecording:
      "Voice recording is empty."
    case .unsupportedInputFormat:
      "The active microphone format isn't supported."
    case .processingFailed:
      "Could not process voice recording."
    }
  }
}

/// The only public handle for one active recording. AVFoundation ownership,
/// temporary files, metering, and post-processing remain inside the recorder.
public final class MacVoiceRecordingSession: @unchecked Sendable {
  public let updates: AsyncThrowingStream<MacVoiceRecordingUpdate, any Error>

  private enum State: Equatable {
    case active
    case finishing
    case ended
  }

  private let lock = NSLock()
  private let id: UUID
  private let recorder: MacVoiceRecorder
  private var state = State.active

  fileprivate init(
    id: UUID,
    updates: AsyncThrowingStream<MacVoiceRecordingUpdate, any Error>,
    recorder: MacVoiceRecorder
  ) {
    self.id = id
    self.updates = updates
    self.recorder = recorder
  }

  deinit {
    guard claimCancellation() else { return }
    recorder.scheduleCancel(id: id)
  }

  public func finish() async throws -> MacVoiceRecording {
    guard claimFinish() else { throw MacVoiceRecorderError.sessionEnded }
    defer { markEnded() }
    return try await recorder.finish(id: id)
  }

  public func cancel() async {
    guard claimCancellation() else { return }
    await recorder.cancel(id: id)
  }

  private func claimFinish() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard state == .active else { return false }
    state = .finishing
    return true
  }

  private func claimCancellation() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard state != .ended else { return false }
    state = .ended
    return true
  }

  private func markEnded() {
    lock.lock()
    state = .ended
    lock.unlock()
  }
}

/// Process-wide macOS voice-message recorder.
///
/// Construction is intentionally inert: no AVFoundation object or microphone
/// input is opened before `start()`. Capture control and offline processing use
/// separate serial queues, neither of which blocks the main actor or chat-open path.
public final class MacVoiceRecorder: @unchecked Sendable {
  public static let shared = MacVoiceRecorder()

  private struct ActiveRecording {
    let id: UUID
    let rawURL: URL
    let finalURL: URL
    let recorder: any MacVoiceRecordingBackend
    let continuation: AsyncThrowingStream<MacVoiceRecordingUpdate, any Error>.Continuation
    let requestedAt: UInt64
    let acceptedAt: UInt64
    let signpostID: OSSignpostID
    var meterTimer: DispatchSourceTimer?
    var samples: [UInt8] = []
    var lastMeterSample: UInt8?
    var didPublishFirstProgress = false
  }

  private struct ProcessingRecording {
    let id: UUID
    let output: MacVoiceCaptureOutput
    let cancellation: MacVoiceProcessingCancellation
  }

  typealias MakeBackend = (URL, [String: Any]) throws -> any MacVoiceRecordingBackend
  typealias ProcessCapture = (
    MacVoiceCaptureOutput,
    MacVoiceProcessingCancellation
  ) throws -> MacVoiceRecording

  private let captureQueue: DispatchQueue
  private let processingQueue: DispatchQueue
  private let makeBackend: MakeBackend
  private let processCapture: ProcessCapture
  private var active: ActiveRecording?
  private var processing: [UUID: ProcessingRecording] = [:]

  private init() {
    captureQueue = DispatchQueue(
      label: "chat.inline.voice-recording",
      qos: .userInitiated
    )
    processingQueue = DispatchQueue(
      label: "chat.inline.voice-recording.processing",
      qos: .userInitiated
    )
    makeBackend = { url, settings in
      try AVAudioRecorderBackend(url: url, settings: settings)
    }
    processCapture = MacVoiceRecordingProcessor.process
  }

  init(
    captureQueue: DispatchQueue = DispatchQueue(label: "chat.inline.voice-recording.tests"),
    processingQueue: DispatchQueue = DispatchQueue(
      label: "chat.inline.voice-recording.processing.tests"
    ),
    makeBackend: @escaping MakeBackend,
    processCapture: @escaping ProcessCapture
  ) {
    self.captureQueue = captureQueue
    self.processingQueue = processingQueue
    self.makeBackend = makeBackend
    self.processCapture = processCapture
  }

  /// Opens the microphone only after this user-initiated method is called.
  public func start() async throws -> MacVoiceRecordingSession {
    let requestedAt = DispatchTime.now().uptimeNanoseconds
    let signpostID = OSSignpostID(log: Self.performanceLog)
    os_signpost(
      .begin,
      log: Self.performanceLog,
      name: "VoiceRecordingStart",
      signpostID: signpostID
    )
    return try await withCheckedThrowingContinuation { continuation in
      captureQueue.async { [self] in
        do {
          continuation.resume(
            returning: try startOnQueue(requestedAt: requestedAt, signpostID: signpostID)
          )
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }

  fileprivate func finish(id: UUID) async throws -> MacVoiceRecording {
    let processing = try await withCheckedThrowingContinuation { continuation in
      captureQueue.async { [self] in
        do {
          continuation.resume(returning: try finishCaptureOnQueue(id: id))
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }

    return try await withTaskCancellationHandler {
      do {
        try Task.checkCancellation()
        let recording = try await process(processing)
        guard await completeProcessing(processing) else {
          Self.removeFiles(processing.output.rawURL, processing.output.finalURL)
          throw CancellationError()
        }
        return recording
      } catch {
        await abandonProcessing(processing)
        throw error
      }
    } onCancel: { [self] in
      processing.cancellation.cancel()
      scheduleCancel(id: id)
    }
  }

  fileprivate func cancel(id: UUID) async {
    await withCheckedContinuation { continuation in
      captureQueue.async { [self] in
        cancelOnQueue(id: id)
        continuation.resume()
      }
    }
  }

  fileprivate func scheduleCancel(id: UUID) {
    captureQueue.async { [self] in
      cancelOnQueue(id: id)
    }
  }

  private func process(
    _ processing: ProcessingRecording
  ) async throws -> MacVoiceRecording {
    try await withCheckedThrowingContinuation { continuation in
      processingQueue.async { [self] in
        do {
          try processing.cancellation.checkCancellation()
          let recording = try processCapture(processing.output, processing.cancellation)
          try processing.cancellation.checkCancellation()
          continuation.resume(returning: recording)
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }

  private func completeProcessing(_ recording: ProcessingRecording) async -> Bool {
    await withCheckedContinuation { continuation in
      captureQueue.async { [self] in
        let isCurrent = processing[recording.id]?.cancellation === recording.cancellation
        if isCurrent {
          processing[recording.id] = nil
        }
        continuation.resume(returning: isCurrent && !recording.cancellation.isCancelled)
      }
    }
  }

  private func abandonProcessing(_ recording: ProcessingRecording) async {
    await withCheckedContinuation { continuation in
      captureQueue.async { [self] in
        if processing[recording.id]?.cancellation === recording.cancellation {
          processing[recording.id] = nil
        }
        Self.removeFiles(recording.output.rawURL, recording.output.finalURL)
        continuation.resume()
      }
    }
  }

  private func startOnQueue(
    requestedAt: UInt64,
    signpostID: OSSignpostID
  ) throws -> MacVoiceRecordingSession {
    dispatchPrecondition(condition: .onQueue(captureQueue))
    guard active == nil else {
      Self.endStartSignpost(signpostID, requestedAt: requestedAt, accepted: false)
      throw MacVoiceRecorderError.busy
    }

    let id = UUID()
    let rawURL = Self.temporaryURL(id: id, fileExtension: "caf")
    let finalURL = Self.temporaryURL(id: id, fileExtension: "m4a")
    var backend: (any MacVoiceRecordingBackend)?

    do {
      let recorder = try makeBackend(rawURL, Self.makeRecordingSettings())
      backend = recorder
      recorder.terminationHandler = { [weak self] termination in
        self?.scheduleBackendTermination(id: id, termination: termination)
      }
      recorder.isMeteringEnabled = true
      guard recorder.prepareToRecord(), recorder.record() else {
        throw MacVoiceRecorderError.startFailed
      }
      let acceptedAt = DispatchTime.now().uptimeNanoseconds

      let stream = AsyncThrowingStream<MacVoiceRecordingUpdate, any Error>.makeStream(
        of: MacVoiceRecordingUpdate.self,
        bufferingPolicy: .bufferingNewest(1)
      )
      active = ActiveRecording(
        id: id,
        rawURL: rawURL,
        finalURL: finalURL,
        recorder: recorder,
        continuation: stream.continuation,
        requestedAt: requestedAt,
        acceptedAt: acceptedAt,
        signpostID: signpostID
      )
      startMeteringOnQueue()

      Self.endStartSignpost(signpostID, requestedAt: requestedAt, accepted: true)
      return MacVoiceRecordingSession(id: id, updates: stream.stream, recorder: self)
    } catch {
      backend?.stop()
      Self.removeFiles(rawURL, finalURL)
      Self.endStartSignpost(signpostID, requestedAt: requestedAt, accepted: false)
      throw error
    }
  }

  private func finishCaptureOnQueue(id: UUID) throws -> ProcessingRecording {
    dispatchPrecondition(condition: .onQueue(captureQueue))
    guard let recording = takeActiveOnQueue(id: id) else {
      throw MacVoiceRecorderError.sessionEnded
    }

    let recorderDuration = recording.recorder.currentTime
    recording.recorder.stop()
    recording.continuation.finish()

    let output = MacVoiceCaptureOutput(
      rawURL: recording.rawURL,
      finalURL: recording.finalURL,
      duration: max(
        recorderDuration,
        TimeInterval(Self.elapsedNanoseconds(since: recording.acceptedAt)) / 1_000_000_000
      ),
      samples: recording.samples
    )
    let processing = ProcessingRecording(
      id: id,
      output: output,
      cancellation: MacVoiceProcessingCancellation()
    )
    self.processing[id] = processing
    return processing
  }

  private func cancelOnQueue(id: UUID) {
    dispatchPrecondition(condition: .onQueue(captureQueue))
    if let recording = takeActiveOnQueue(id: id) {
      recording.recorder.stop()
      recording.continuation.finish()
      Self.removeFiles(recording.rawURL, recording.finalURL)
      return
    }

    guard let processing = processing.removeValue(forKey: id) else { return }
    processing.cancellation.cancel()
    Self.removeFiles(processing.output.rawURL, processing.output.finalURL)
  }

  private func takeActiveOnQueue(id: UUID) -> ActiveRecording? {
    guard var recording = active, recording.id == id else { return nil }
    recording.meterTimer?.setEventHandler {}
    recording.meterTimer?.cancel()
    recording.meterTimer = nil
    recording.recorder.terminationHandler = nil
    active = nil
    return recording
  }

  private func startMeteringOnQueue() {
    guard var recording = active else { return }
    let timer = DispatchSource.makeTimerSource(queue: captureQueue)
    timer.schedule(deadline: .now() + Self.meterInterval, repeating: Self.meterInterval)
    timer.setEventHandler { [weak self] in
      self?.publishMeterOnQueue()
    }
    recording.meterTimer = timer
    active = recording
    timer.resume()
  }

  private func publishMeterOnQueue() {
    dispatchPrecondition(condition: .onQueue(captureQueue))
    guard var recording = active else { return }
    guard recording.recorder.isRecording else {
      terminateRecordingOnQueue(id: recording.id, termination: .stoppedUnexpectedly)
      return
    }

    recording.recorder.updateMeters()
    let sample = Self.meterSample(
      fromAveragePower: recording.recorder.averagePower(forChannel: 0)
    )
    let smoothed = Self.smoothedMeterSample(sample, previous: recording.lastMeterSample)
    recording.samples.append(smoothed)
    recording.lastMeterSample = smoothed

    if !recording.didPublishFirstProgress, recording.recorder.currentTime > 0 {
      recording.didPublishFirstProgress = true
      os_signpost(
        .event,
        log: Self.performanceLog,
        name: "VoiceRecordingFirstProgress",
        signpostID: recording.signpostID,
        "duration_ms=%{public}llu",
        Self.elapsedMilliseconds(since: recording.requestedAt)
      )
    }

    recording.continuation.yield(
      MacVoiceRecordingUpdate(
        duration: max(0, recording.recorder.currentTime),
        samples: Self.liveSamples(from: recording.samples)
      )
    )
    active = recording
  }

  private func scheduleBackendTermination(
    id: UUID,
    termination: MacVoiceRecordingBackendTermination
  ) {
    captureQueue.async { [self] in
      terminateRecordingOnQueue(id: id, termination: termination)
    }
  }

  private func terminateRecordingOnQueue(
    id: UUID,
    termination: MacVoiceRecordingBackendTermination
  ) {
    dispatchPrecondition(condition: .onQueue(captureQueue))
    guard let recording = takeActiveOnQueue(id: id) else { return }
    recording.recorder.stop()
    recording.continuation.finish(throwing: termination.error)
    Self.removeFiles(recording.rawURL, recording.finalURL)
  }

  private static func meterSample(fromAveragePower power: Float) -> UInt8 {
    let normalized = normalizedPower(power)
    return UInt8(max(0, min(255, Int((normalized * 255).rounded()))))
  }

  private static func normalizedPower(_ power: Float) -> Float {
    guard power.isFinite else { return 0 }
    if power <= -60 { return 0 }
    if power >= 0 { return 1 }
    return pow(pow(10, power / 20), 0.55)
  }

  private static func smoothedMeterSample(_ sample: UInt8, previous: UInt8?) -> UInt8 {
    guard let previous else { return sample }
    let current = Float(sample)
    let prior = Float(previous)
    let response = current >= prior ? meterAttack : meterRelease
    return UInt8(max(0, min(255, Int((prior + (current - prior) * response).rounded()))))
  }

  private static func liveSamples(from samples: [UInt8]) -> [UInt8] {
    guard samples.count < liveSampleCount else { return Array(samples.suffix(liveSampleCount)) }
    return Array(repeating: 0, count: liveSampleCount - samples.count) + samples
  }

  private static func temporaryURL(id: UUID, fileExtension: String) -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("inline-voice-\(id.uuidString).\(fileExtension)")
  }

  private static func removeFiles(_ urls: URL...) {
    for url in urls {
      try? FileManager.default.removeItem(at: url)
    }
  }

  private static func elapsedNanoseconds(since start: UInt64) -> UInt64 {
    let now = DispatchTime.now().uptimeNanoseconds
    return now >= start ? now - start : 0
  }

  private static func elapsedMilliseconds(since start: UInt64) -> UInt64 {
    elapsedNanoseconds(since: start) / 1_000_000
  }

  private static func endStartSignpost(
    _ signpostID: OSSignpostID,
    requestedAt: UInt64,
    accepted: Bool
  ) {
    os_signpost(
      .end,
      log: performanceLog,
      name: "VoiceRecordingStart",
      signpostID: signpostID,
      "accepted=%{public}@ duration_ms=%{public}llu",
      accepted ? "true" : "false",
      elapsedMilliseconds(since: requestedAt)
    )
  }

  private static let performanceLog = OSLog(
    subsystem: Bundle.main.bundleIdentifier ?? "chat.inline",
    category: "VoiceRecording"
  )
  private static func makeRecordingSettings() -> [String: Any] {
    [
      AVFormatIDKey: Int(kAudioFormatLinearPCM),
      AVSampleRateKey: 48_000,
      AVNumberOfChannelsKey: 1,
      AVLinearPCMBitDepthKey: 32,
      AVLinearPCMIsFloatKey: true,
      AVLinearPCMIsBigEndianKey: false,
      AVLinearPCMIsNonInterleaved: false,
    ]
  }
  private static let meterInterval: DispatchTimeInterval = .milliseconds(33)
  private static let liveSampleCount = 160
  private static let meterAttack: Float = 0.72
  private static let meterRelease: Float = 0.28
}

final class MacVoiceProcessingCancellation: @unchecked Sendable {
  private let lock = NSLock()
  private var cancelled = false

  var isCancelled: Bool {
    lock.lock()
    defer { lock.unlock() }
    return cancelled
  }

  func cancel() {
    lock.lock()
    cancelled = true
    lock.unlock()
  }

  func checkCancellation() throws {
    if isCancelled {
      throw CancellationError()
    }
  }
}

enum MacVoiceRecordingBackendTermination: Sendable {
  case stoppedUnexpectedly
  case encodingFailed

  var error: MacVoiceRecorderError {
    switch self {
    case .stoppedUnexpectedly:
      .recordingInterrupted
    case .encodingFailed:
      .encodingFailed
    }
  }
}

protocol MacVoiceRecordingBackend: AnyObject {
  var isRecording: Bool { get }
  var currentTime: TimeInterval { get }
  var isMeteringEnabled: Bool { get set }
  var terminationHandler: (@Sendable (MacVoiceRecordingBackendTermination) -> Void)? { get set }

  func prepareToRecord() -> Bool
  func record() -> Bool
  func stop()
  func updateMeters()
  func averagePower(forChannel channelNumber: Int) -> Float
}

private final class AVAudioRecorderBackend: NSObject, MacVoiceRecordingBackend,
  AVAudioRecorderDelegate, @unchecked Sendable {
  private let recorder: AVAudioRecorder
  private let handlerLock = NSLock()
  private var storedTerminationHandler:
    (@Sendable (MacVoiceRecordingBackendTermination) -> Void)?

  var terminationHandler: (@Sendable (MacVoiceRecordingBackendTermination) -> Void)? {
    get {
      handlerLock.lock()
      defer { handlerLock.unlock() }
      return storedTerminationHandler
    }
    set {
      handlerLock.lock()
      storedTerminationHandler = newValue
      handlerLock.unlock()
    }
  }

  var isRecording: Bool { recorder.isRecording }
  var currentTime: TimeInterval { recorder.currentTime }
  var isMeteringEnabled: Bool {
    get { recorder.isMeteringEnabled }
    set { recorder.isMeteringEnabled = newValue }
  }

  init(url: URL, settings: [String: Any]) throws {
    recorder = try AVAudioRecorder(url: url, settings: settings)
    super.init()
    recorder.delegate = self
  }

  func prepareToRecord() -> Bool {
    recorder.prepareToRecord()
  }

  func record() -> Bool {
    recorder.record()
  }

  func stop() {
    recorder.stop()
  }

  func updateMeters() {
    recorder.updateMeters()
  }

  func averagePower(forChannel channelNumber: Int) -> Float {
    recorder.averagePower(forChannel: channelNumber)
  }

  func audioRecorderDidFinishRecording(_: AVAudioRecorder, successfully _: Bool) {
    terminationHandler?(.stoppedUnexpectedly)
  }

  func audioRecorderEncodeErrorDidOccur(_: AVAudioRecorder, error _: (any Error)?) {
    terminationHandler?(.encodingFailed)
  }
}
