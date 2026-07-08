import Foundation
import Testing

@testable import InlineAudioPlayback

@MainActor
@Suite("Audio playback center")
struct AudioPlaybackCenterTests {
  @Test("play exposes now-playing presentation")
  func playExposesNowPlayingPresentation() throws {
    let engine = TestAudioPlaybackEngine(duration: 42)
    let center = AudioPlaybackCenter(engine: engine, userDefaults: makeUserDefaults())
    let item = makeItem()
    let presentation = makePresentation()
    let fileURL = makeFileURL()

    try center.play(fileURL: fileURL, item: item, presentation: presentation)

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
  func toggleOrPlayReloadsCurrentItemWhenSourceURLChanges() throws {
    let engine = TestAudioPlaybackEngine(duration: 42)
    let center = AudioPlaybackCenter(engine: engine, userDefaults: makeUserDefaults())
    let item = makeItem()
    let presentation = makePresentation()
    let firstURL = makeFileURL()
    let secondURL = makeFileURL()

    try center.toggleOrPlay(fileURL: firstURL, item: item, presentation: presentation)
    #expect(engine.loadedURL == firstURL)
    #expect(engine.loadCount == 1)
    #expect(center.isPlaying)

    try center.toggleOrPlay(fileURL: firstURL, item: item, presentation: presentation)
    #expect(engine.loadedURL == firstURL)
    #expect(engine.loadCount == 1)
    #expect(center.isPlaying == false)

    try center.toggleOrPlay(fileURL: secondURL, item: item, presentation: presentation)
    #expect(engine.loadedURL == secondURL)
    #expect(engine.loadCount == 2)
    #expect(center.sourceURL == secondURL)
    #expect(center.isPlaying)
  }

  @Test("preview volume avoids observable and stored volume churn")
  func previewVolumeAvoidsObservableAndStoredVolumeChurn() throws {
    let defaults = makeUserDefaults()
    let engine = TestAudioPlaybackEngine()
    let center = AudioPlaybackCenter(engine: engine, userDefaults: defaults)

    try center.play(fileURL: makeFileURL(), item: makeItem(), presentation: makePresentation())
    center.setVolume(0.8)
    center.previewVolume(0.25)

    #expect(abs(engine.volume - 0.25) < 0.001)
    #expect(abs(center.volume - 0.8) < 0.001)

    let nextEngine = TestAudioPlaybackEngine()
    let nextCenter = AudioPlaybackCenter(engine: nextEngine, userDefaults: defaults)
    #expect(abs(nextCenter.volume - 0.8) < 0.001)
  }

  @Test("finish closes now-playing while preserving controls")
  func finishClosesNowPlayingWhilePreservingControls() throws {
    let engine = TestAudioPlaybackEngine(duration: 9)
    let center = AudioPlaybackCenter(engine: engine, userDefaults: makeUserDefaults())

    center.setPlaybackRate(1.5)
    center.setVolume(0.6)
    try center.play(fileURL: makeFileURL(), item: makeItem(), presentation: makePresentation())
    engine.finish()

    #expect(center.item == nil)
    #expect(center.sourceURL == nil)
    #expect(center.display == nil)
    #expect(center.openTarget == nil)
    #expect(center.isPlaying == false)
    #expect(center.currentTime == 0)
    #expect(center.duration == 0)
    #expect(abs(center.playbackRate - 1.5) < 0.001)
    #expect(abs(center.volume - 0.6) < 0.001)
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
  private(set) var loadedURL: URL?
  private(set) var loadCount = 0

  init(duration: TimeInterval = 12) {
    self.duration = duration
  }

  func load(contentsOf fileURL: URL) throws {
    loadedURL = fileURL
    loadCount += 1
    currentTime = 0
  }

  func prepare() {}

  func play() -> Bool {
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
