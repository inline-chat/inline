import Foundation
import Testing
#if os(iOS)
import AVFAudio
#endif

@testable import InlineAudioPlayback

@MainActor
@Suite("Audio playback center")
struct AudioPlaybackCenterTests {
  @Test("loading and paused seeking never prepare playback hardware")
  func loadingAndPausedSeekingDoNotPrepareHardware() async throws {
    var releases = 0
    let session = InlineAudioSession(deactivate: { releases += 1 })
    let videoToken = try session.acquire(.video)
    defer { session.release(videoToken) }
    let engine = TestAudioPlaybackEngine(duration: 42)
    let center = AudioPlaybackCenter(engine: engine, userDefaults: makeUserDefaults(), audioSession: session)
    defer { center.close() }
    let item = makeItem()
    let fileURL = makeFileURL()

    try center.prepare(fileURL: fileURL, item: item, presentation: makePresentation())
    #expect(center.duration == 42)
    #expect(center.seek(to: 0.5))
    #expect(center.currentTime == 21)
    try center.prepare(fileURL: fileURL, item: item, presentation: makePresentation())

    #expect(engine.loadCount == 1)
    #expect(engine.prepareCount == 0)
    #expect(engine.playCount == 0)
    #expect(!center.isPlaying)
    #expect(session.owns(videoToken))
    #expect(releases == 0)
    #if os(iOS)
    await #expect(throws: AudioPlaybackError.self) {
      try await startPlayback { try center.resume(completion: $0) }
    }
    #expect(engine.prepareCount == 0)
    #expect(session.owns(videoToken))
    #expect(releases == 0)
    #endif

    session.release(videoToken)
    try await startPlayback { completion in
      try center.resume(completion: completion)
    }
    #expect(engine.prepareCount == 1)
    #expect(engine.playCount == 1)
    center.pause()
    #expect(center.seek(toTime: 10))
    #expect(center.currentTime == 10)
    #expect(engine.prepareCount == 1)
  }

  @Test("preparation failure retains the loaded selection and seek position for retry")
  func preparationFailureRetainsSelectionForRetry() async throws {
    var releases = 0
    let session = InlineAudioSession(deactivate: { releases += 1 })
    let engine = TestAudioPlaybackEngine(duration: 42)
    let center = AudioPlaybackCenter(engine: engine, userDefaults: makeUserDefaults(), audioSession: session)
    defer { center.close() }
    let item = makeItem()
    let fileURL = makeFileURL()
    try center.prepare(fileURL: fileURL, item: item, presentation: makePresentation())
    #expect(center.seek(toTime: 12))
    engine.permitsPreparation = false

    await #expect(throws: AudioPlaybackError.self) {
      try await startPlayback { try center.resume(completion: $0) }
    }
    #expect(engine.prepareCount == 1)
    #expect(engine.playCount == 0)
    #expect(engine.loadedURL == fileURL)
    #expect(center.item == item)
    #expect(center.sourceURL == fileURL)
    #expect(center.currentTime == 12)
    #expect(!center.isPlaying)
    #expect(center.playbackError != nil)
    #expect(session.current == nil)
    #if os(iOS)
    #expect(releases == 1)
    #endif

    engine.permitsPreparation = true
    try await startPlayback { completion in
      try center.resume(completion: completion)
    }
    #expect(engine.loadCount == 1)
    #expect(engine.prepareCount == 2)
    #expect(engine.playCount == 1)
    #expect(engine.currentTime == 12)
    #expect(center.isPlaying)
    #expect(center.playbackError == nil)
  }

  #if os(iOS)
  @Test("iOS playback preparation observes the owned playback session")
  func preparationFollowsOwnedSessionActivation() async throws {
    let session = InlineAudioSession()
    let engine = TestAudioPlaybackEngine()
    let center = AudioPlaybackCenter(engine: engine, userDefaults: makeUserDefaults(), audioSession: session)
    defer { center.close() }
    engine.onPrepare = { [weak engine] in
      #expect(session.current?.owner == .voice)
      #expect(AVAudioSession.sharedInstance().category == .playback)
      #expect(AVAudioSession.sharedInstance().mode == .spokenAudio)
      #expect(engine?.isPlaying == false)
    }

    try center.prepare(fileURL: makeFileURL(), item: makeItem(), presentation: makePresentation())
    #expect(session.current == nil)
    #expect(engine.prepareCount == 0)
    try await startPlayback { completion in
      try center.resume(completion: completion)
    }
    #expect(engine.prepareCount == 1)
    #expect(engine.playCount == 1)
    #expect(center.isPlaying)
  }

  @Test("failed preparation cannot release a newer audio session generation")
  func preparationFailurePreservesNewerSessionOwner() async throws {
    var releases = 0
    let session = InlineAudioSession(deactivate: { releases += 1 })
    let engine = TestAudioPlaybackEngine()
    let center = AudioPlaybackCenter(engine: engine, userDefaults: makeUserDefaults(), audioSession: session)
    var videoToken: InlineAudioSession.Token?
    defer {
      center.close()
      if let videoToken { session.release(videoToken) }
    }
    engine.onPrepare = {
      session.invalidate()
      videoToken = try? session.acquire(.video)
    }
    engine.permitsPreparation = false

    await #expect(throws: AudioPlaybackError.self) {
      try await startPlayback { completion in
        try center.play(fileURL: makeFileURL(), item: makeItem(), presentation: makePresentation(), completion: completion)
      }
    }
    let currentVideo = try #require(videoToken)
    #expect(session.owns(currentVideo))
    #expect(releases == 0)
    #expect(engine.playCount == 0)
    #expect(center.item == makeItem())
    #expect(!center.isPlaying)
  }
  #endif

  @Test("play exposes now-playing presentation")
  func playExposesNowPlayingPresentation() async throws {
    let engine = TestAudioPlaybackEngine(duration: 42)
    let center = AudioPlaybackCenter(engine: engine, userDefaults: makeUserDefaults())
    let item = makeItem()
    let presentation = makePresentation()
    let fileURL = makeFileURL()

    try await startPlayback { completion in
      try center.play(fileURL: fileURL, item: item, presentation: presentation, completion: completion)
    }

    #expect(engine.loadedURL == fileURL)
    #expect(engine.isPlaying)
    #expect(center.item == item)
    #expect(center.sourceURL == fileURL)
    #expect(center.display == presentation.display)
    #expect(center.openTarget == presentation.openTarget)
    #expect(center.duration == 42)
    #expect(center.isPlaying)
  }

  @Test("toggle or play reloads current item when source URL changes")
  func toggleOrPlayReloadsCurrentItemWhenSourceURLChanges() async throws {
    let engine = TestAudioPlaybackEngine(duration: 42)
    let center = AudioPlaybackCenter(engine: engine, userDefaults: makeUserDefaults())
    let item = makeItem()
    let presentation = makePresentation()
    let firstURL = makeFileURL()
    let secondURL = makeFileURL()

    try await startPlayback { completion in
      try center.toggleOrPlay(fileURL: firstURL, item: item, presentation: presentation, completion: completion)
    }
    #expect(engine.loadedURL == firstURL)
    #expect(engine.loadCount == 1)
    #expect(center.isPlaying)

    try await startPlayback { completion in
      try center.toggleOrPlay(fileURL: firstURL, item: item, presentation: presentation, completion: completion)
    }
    #expect(engine.loadedURL == firstURL)
    #expect(engine.loadCount == 1)
    #expect(center.isPlaying == false)

    try await startPlayback { completion in
      try center.toggleOrPlay(fileURL: secondURL, item: item, presentation: presentation, completion: completion)
    }
    #expect(engine.loadedURL == secondURL)
    #expect(engine.loadCount == 2)
    #expect(center.sourceURL == secondURL)
    #expect(center.isPlaying)
  }

  #if !os(iOS)
  @Test("preview volume avoids observable and stored volume churn")
  func previewVolumeAvoidsObservableAndStoredVolumeChurn() async throws {
    let defaults = makeUserDefaults()
    let engine = TestAudioPlaybackEngine()
    let center = AudioPlaybackCenter(engine: engine, userDefaults: defaults)

    try await startPlayback { completion in
      try center.play(fileURL: makeFileURL(), item: makeItem(), presentation: makePresentation(), completion: completion)
    }
    center.setVolume(0.8)
    center.previewVolume(0.25)

    #expect(abs(engine.volume - 0.25) < 0.001)
    #expect(abs(center.volume - 0.8) < 0.001)

    let nextEngine = TestAudioPlaybackEngine()
    let nextCenter = AudioPlaybackCenter(engine: nextEngine, userDefaults: defaults)
    #expect(abs(nextCenter.volume - 0.8) < 0.001)
  }

  #endif

  @Test("finish closes now-playing while preserving controls")
  func finishClosesNowPlayingWhilePreservingControls() async throws {
    let engine = TestAudioPlaybackEngine(duration: 9)
    let center = AudioPlaybackCenter(engine: engine, userDefaults: makeUserDefaults())

    center.setPlaybackRate(1.5)
    center.setVolume(0.6)
    try await startPlayback { completion in
      try center.play(fileURL: makeFileURL(), item: makeItem(), presentation: makePresentation(), completion: completion)
    }
    engine.finish()

    #expect(center.item == nil)
    #expect(center.sourceURL == nil)
    #expect(center.display == nil)
    #expect(center.openTarget == nil)
    #expect(center.isPlaying == false)
    #expect(center.currentTime == 0)
    #expect(center.duration == 0)
    #expect(abs(center.playbackRate - 1.5) < 0.001)
    #if os(iOS)
    #expect(center.volume == 1)
    #else
    #expect(abs(center.volume - 0.6) < 0.001)
    #endif
  }
}

@MainActor
private final class TestAudioPlaybackEngine: AudioPlaybackEngine {
  var currentTime: TimeInterval = 0
  var duration: TimeInterval
  var isPlaying = false
  var playbackRate: Float = 1
  var volume: Float = 1
  var onFinish: ((TimeInterval) -> Void)?
  var onFailure: (() -> Void)?
  private(set) var loadedURL: URL?
  private(set) var loadCount = 0
  private(set) var prepareCount = 0
  private(set) var playCount = 0
  var permitsPreparation = true
  var onPrepare: (() -> Void)?

  init(duration: TimeInterval = 12) {
    self.duration = duration
  }

  func load(contentsOf fileURL: URL) throws {
    loadedURL = fileURL
    loadCount += 1
    currentTime = 0
  }

  func prepare() throws {
    prepareCount += 1
    onPrepare?()
    guard permitsPreparation else { throw AudioPlaybackError.preparationFailed }
  }

  func play() -> Bool {
    playCount += 1
    isPlaying = true
    return true
  }

  func pause() {
    isPlaying = false
  }

  func stop() {
    isPlaying = false
    loadedURL = nil
    currentTime = 0
  }

  func finish() {
    isPlaying = false
    onFinish?(duration)
  }
}

private func makeItem() -> AudioPlaybackItem {
  AudioPlaybackItem(kind: .voice, chatId: 1, messageId: 2, mediaId: 3)
}

private func makePresentation() -> AudioPlaybackPresentation {
  AudioPlaybackPresentation(
    display: AudioPlaybackDisplay(
      title: "Voice message from Mo",
      parentTitle: "Design chat",
      subtitle: "0:42"
    ),
    openTarget: AudioPlaybackOpenTarget(
      peer: .thread(id: 4),
      chatId: 1,
      messageId: 2
    )
  )
}

private func makeFileURL() -> URL {
  URL(fileURLWithPath: "/tmp/audio-\(UUID().uuidString).m4a")
}

private func makeUserDefaults() -> UserDefaults {
  let suiteName = "AudioPlaybackCenterTests-\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: suiteName) ?? .standard
  defaults.removePersistentDomain(forName: suiteName)
  return defaults
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
