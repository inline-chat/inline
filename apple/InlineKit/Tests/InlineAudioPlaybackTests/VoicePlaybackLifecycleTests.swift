import AVFoundation
import Foundation
import Testing
@testable import InlineAudioPlayback

@MainActor
@Suite("Voice playback lifecycle", .serialized)
struct VoicePlaybackLifecycleTests {
  @Test("real PCM file supports timing, rate, pause and seek")
  func actualEngine() async throws {
    let engine = AVAudioPlayerPlaybackEngine()
    let center = AudioPlaybackCenter(engine: engine, userDefaults: defaults())
    let url = try pcmFile(seconds: 2)
    defer { center.close() }
    try center.prepare(fileURL: url, item: voice(), presentation: presentation())
    #expect(!center.isPlaying)
    #expect(abs(center.duration - 2) < 0.01)
    center.setPlaybackRate(2)
    try await startPlayback { completion in
      try center.resume(completion: completion)
    }
    try await Task.sleep(for: .milliseconds(180))
    center.pause()
    #expect(center.currentTime > 0.1)
    #expect(engine.player?.rate == 2)
    #expect(center.seek(to: 0.5))
    #expect(abs(center.currentTime - 1) < 0.01)
    #expect(!center.isPlaying)
    #expect(!center.seek(to: .nan))
    #expect(center.seek(to: 1))
    try await startPlayback { completion in
      try center.resume(completion: completion)
    }
    #expect(center.currentTime < 0.2)
  }

  @Test("actual completion clears the selected item")
  func actualCompletion() async throws {
    let center = AudioPlaybackCenter(userDefaults: defaults())
    try await startPlayback { completion in
      try center.play(fileURL: pcmFile(seconds: 0.15), item: voice(), presentation: presentation(), completion: completion)
    }
    defer { center.close() }
    for _ in 0..<40 {
      if center.item == nil { break }
      try await Task.sleep(for: .milliseconds(50))
    }
    #expect(center.item == nil)
  }

  @Test("corrupt local file leaves idle")
  func corruptFile() async throws {
    let center = AudioPlaybackCenter(userDefaults: defaults())
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("inline-corrupt-\(UUID()).wav")
    try Data("invalid audio".utf8).write(to: url)
    #expect(throws: (any Error).self) { try center.play(fileURL: url, item: voice(), presentation: presentation()) }
    #expect(center.item == nil)
    #expect(!center.isPlaying)
  }

  @Test("obsolete actual-player finish and decode errors cannot close the successor")
  func stalePlayer() async throws {
    let engine = AVAudioPlayerPlaybackEngine()
    let center = AudioPlaybackCenter(engine: engine, userDefaults: defaults())
    let url = try pcmFile(seconds: 1)
    try center.prepare(fileURL: url, item: voice(1), presentation: presentation())
    let old = try #require(engine.player)
    try center.prepare(fileURL: url, item: voice(2), presentation: presentation())
    engine.audioPlayerDidFinishPlaying(old, successfully: true)
    engine.audioPlayerDecodeErrorDidOccur(old, error: nil)
    await Task.yield()
    #expect(center.item == voice(2))
    let current = try #require(engine.player)
    engine.audioPlayerDidFinishPlaying(current, successfully: false)
    await Task.yield()
    #expect(center.item == nil)
    #expect(center.playbackError != nil)
  }

  @Test("failed start retains prepared audio and explicit pause cancels interruption resume")
  func failedStartAndInterruption() async throws {
    let engine = LifecycleEngine()
    let center = AudioPlaybackCenter(engine: engine, userDefaults: defaults())
    engine.permitsPlay = false
    await #expect(throws: AudioPlaybackError.self) {
      try await startPlayback { completion in
        try center.play(fileURL: URL(fileURLWithPath: "/test.wav"), item: voice(), presentation: presentation(), completion: completion)
      }
    }
    #expect(center.item == voice())
    #expect(!center.isPlaying)
    engine.permitsPlay = true
    try await startPlayback { completion in
      try center.resume(completion: completion)
    }
    center.interruptionBegan()
    center.pause()
    center.interruptionEnded(shouldResume: true, outputAvailable: true)
    try await finishAdmittedStart(center)
    #expect(!center.isPlaying)
    try await startPlayback { completion in
      try center.resume(completion: completion)
    }
    center.interruptionBegan()
    center.interruptionEnded(shouldResume: true, outputAvailable: true)
    try await finishAdmittedStart(center)
    #expect(center.isPlaying)
    center.outputWasRemoved()
    center.interruptionEnded(shouldResume: true, outputAvailable: true)
    try await finishAdmittedStart(center)
    #expect(!center.isPlaying)
    center.close()
  }

  @Test("remote admission captures publication before dispatch and rejects item replay")
  func remoteAdmission() async throws {
    let engine = LifecycleEngine()
    let session = InlineAudioSession()
    let center = AudioPlaybackCenter(engine: engine, userDefaults: defaults(), audioSession: session)
    let admission = AudioPlaybackCommandAdmission()
    try await startPlayback { completion in
      try center.play(fileURL: URL(fileURLWithPath: "/test.wav"), item: voice(), presentation: presentation(), completion: completion)
    }
    admission.publish(center.remoteCommandIdentity)
    let accepted = admission.receive(unavailable: false) { received in
      center.close()
      try? center.play(fileURL: URL(fileURLWithPath: "/test.wav"), item: voice(), presentation: presentation())
      return center.handleRemoteCommand(.pause, expectedIdentity: received)
    }
    #expect(!accepted)
    try await finishAdmittedStart(center)
    #expect(center.isPlaying)
    center.pause()
    admission.publish(center.remoteCommandIdentity)
    #expect(admission.receive(unavailable: false) { center.handleRemoteCommand(.seek(3), expectedIdentity: $0) })
    #expect(!center.isPlaying)
    #expect(session.current == nil)
    let videoToken = try session.acquire(.video)
    admission.publish(center.remoteCommandIdentity)
    #expect(!admission.receive(unavailable: false) { center.handleRemoteCommand(.play, expectedIdentity: $0) })
    session.release(videoToken)
    center.close()
  }

  @Test("sampling an OS-stopped engine does not lose interruption resume intent")
  func interruptionAfterEngineStops() async throws {
    let engine = AVAudioPlayerPlaybackEngine()
    let center = AudioPlaybackCenter(engine: engine, userDefaults: defaults())
    defer { center.close() }
    try await startPlayback { completion in
      try center.play(fileURL: pcmFile(seconds: 2), item: voice(), presentation: presentation(), completion: completion)
    }
    // AVAudioPlayer may stop before the interruption notification reaches the owner.
    engine.pause()
    center.setProgressVisible(true)
    center.interruptionBegan()
    center.interruptionEnded(shouldResume: true, outputAvailable: true)
    try await finishAdmittedStart(center)
    #expect(center.isPlaying)
    #expect(engine.isPlaying)
  }

  @Test("an interrupted memo remains remotely resumable without automatic resumption")
  func pausedRemoteControlsAfterInterruption() async throws {
    let center = AudioPlaybackCenter(engine: LifecycleEngine(), userDefaults: defaults())
    defer { center.close() }
    try await startPlayback { completion in
      try center.play(fileURL: URL(fileURLWithPath: "/test.wav"), item: voice(), presentation: presentation(), completion: completion)
    }
    center.interruptionBegan()
    // A user Pause during the interruption cancels the saved automatic intent.
    let pausedIdentity = try #require(center.remoteCommandIdentity)
    #expect(center.handleRemoteCommand(.pause, expectedIdentity: pausedIdentity))
    center.interruptionEnded(shouldResume: true, outputAvailable: true)
    try await finishAdmittedStart(center)
    #expect(!center.isPlaying)
    let resumeIdentity = try #require(center.remoteCommandIdentity)
    #expect(center.handleRemoteCommand(.play, expectedIdentity: resumeIdentity))
    try await finishAdmittedStart(center)
    #expect(center.isPlaying)
    center.interruptionBegan()
    center.interruptionEnded(shouldResume: false, outputAvailable: true)
    try await finishAdmittedStart(center)
    #expect(!center.isPlaying)
    let manualResume = try #require(center.remoteCommandIdentity)
    #expect(center.handleRemoteCommand(.play, expectedIdentity: manualResume))
    try await finishAdmittedStart(center)
    #expect(center.isPlaying)
  }

  @Test("stale audio owner release never deactivates a newer owner")
  func sessionGeneration() async throws {
    var releases = 0
    let session = InlineAudioSession(deactivate: { releases += 1 })
    let voice = try session.acquire(.voice)
    session.willAcquire = { _ in session.release(voice) }
    let recording = try session.acquire(.recording)
    #expect(releases == 1)
    session.release(voice)
    #expect(releases == 1)
    #expect(session.owns(recording))
    #expect(throws: AudioPlaybackError.self) { try session.acquire(.voice) }
    session.release(recording)
    #expect(releases == 2)
  }

  @Test("seek to end closes a playing engine even if it stops during the seek")
  func seekEnd() async throws {
    let engine = LifecycleEngine()
    let center = AudioPlaybackCenter(engine: engine, userDefaults: defaults())
    try await startPlayback { completion in
      try center.play(fileURL: URL(fileURLWithPath: "/test.wav"), item: voice(), presentation: presentation(), completion: completion)
    }
    #expect(center.seek(to: 1))
    #expect(center.item == nil)
    #expect(!center.seek(toTime: .infinity))
  }
}

@MainActor
private final class LifecycleEngine: AudioPlaybackEngine {
  var currentTime: TimeInterval = 0 { didSet { if currentTime >= duration { isPlaying = false } } }
  var duration: TimeInterval = 10
  var isPlaying = false
  var playbackRate: Float = 1
  var volume: Float = 1
  var onFinish: ((TimeInterval) -> Void)?
  var onFailure: (() -> Void)?
  var permitsPlay = true
  func load(contentsOf _: URL) throws { currentTime = 0 }
  func prepare() throws {}
  func play() -> Bool { isPlaying = permitsPlay; return permitsPlay }
  func pause() { isPlaying = false }
  func stop() { isPlaying = false; currentTime = 0 }
}

private func voice(_ messageID: Int64 = 1) -> AudioPlaybackItem {
  AudioPlaybackItem(kind: .voice, chatId: 7, messageId: messageID, mediaId: messageID)
}
private func presentation() -> AudioPlaybackPresentation {
  AudioPlaybackPresentation(display: AudioPlaybackDisplay(title: "Voice message from Test", parentTitle: "Test chat"))
}
private func defaults() -> UserDefaults {
  UserDefaults(suiteName: "VoicePlayback-\(UUID())")!
}
private func pcmFile(seconds: Double) throws -> URL {
  let sampleRate = 8_000
  let bytes = UInt32(Double(sampleRate) * seconds) * 2
  var data = Data()
  func ascii(_ value: String) { data.append(contentsOf: value.utf8) }
  func little<T: FixedWidthInteger>(_ value: T) {
    var little = value.littleEndian
    withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
  }
  ascii("RIFF"); little(UInt32(36) + bytes); ascii("WAVEfmt "); little(UInt32(16))
  little(UInt16(1)); little(UInt16(1)); little(UInt32(sampleRate)); little(UInt32(sampleRate * 2))
  little(UInt16(2)); little(UInt16(16)); ascii("data"); little(bytes)
  data.append(Data(repeating: 0, count: Int(bytes)))
  let url = FileManager.default.temporaryDirectory.appendingPathComponent("inline-voice-fixture-\(UUID()).wav")
  try data.write(to: url)
  return url
}

@MainActor
private func startPlayback(
  _ admit: (AudioPlaybackCenter.Completion?) throws -> Void
) async throws {
  #if os(iOS)
  try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
    do { try admit { continuation.resume(with: $0) } }
    catch { continuation.resume(throwing: error) }
  }
  #else
  // The native macOS baseline still exercises synchronous admission and engine start.
  try admit(nil)
  #endif
}

@MainActor
private func finishAdmittedStart(_ center: AudioPlaybackCenter) async throws {
  #if os(iOS)
  for _ in 0..<500 {
    if !center.isStarting { return }
    try await Task.sleep(for: .milliseconds(10))
  }
  try #require(!center.isStarting, "Admitted playback activation did not complete")
  #endif
}
