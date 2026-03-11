import AVFoundation
import Combine
import Foundation
import Logger

public struct SharedAudioPlayerItem: Equatable, Sendable {
  public enum Kind: String, Sendable {
    case voice
    case music
  }

  public let kind: Kind
  public let chatId: Int64
  public let messageId: Int64
  public let mediaId: Int64

  public init(kind: Kind, chatId: Int64, messageId: Int64, mediaId: Int64) {
    self.kind = kind
    self.chatId = chatId
    self.messageId = messageId
    self.mediaId = mediaId
  }
}

public struct SharedAudioPlayerState: Equatable, Sendable {
  public var item: SharedAudioPlayerItem?
  public var isPlaying: Bool
  public var currentTime: TimeInterval
  public var duration: TimeInterval

  public init(
    item: SharedAudioPlayerItem? = nil,
    isPlaying: Bool = false,
    currentTime: TimeInterval = 0,
    duration: TimeInterval = 0
  ) {
    self.item = item
    self.isPlaying = isPlaying
    self.currentTime = currentTime
    self.duration = duration
  }
}

public enum SharedAudioPlayerError: LocalizedError {
  case missingVoice
  case missingLocalFile

  public var errorDescription: String? {
    switch self {
    case .missingVoice:
      "The selected message doesn't contain a playable voice payload."
    case .missingLocalFile:
      "The selected voice message isn't downloaded yet."
    }
  }
}

@MainActor
public final class SharedAudioPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
  public static let shared = SharedAudioPlayer()

  @Published public private(set) var state = SharedAudioPlayerState()

  private let log = Log.scoped("SharedAudioPlayer")
  private var audioPlayer: AVAudioPlayer?
  private var progressTimer: Timer?

  override private init() {
    super.init()
  }

  public func toggleVoicePlayback(for message: Message, fileURLOverride: URL? = nil) throws {
    let item = try voiceItem(for: message)

    if state.item == item {
      if state.isPlaying {
        pause()
      } else {
        try resumeOrRestartVoicePlayback(for: message, fileURLOverride: fileURLOverride)
      }
      return
    }

    try playVoice(for: message, fileURLOverride: fileURLOverride)
  }

  public func playVoice(for message: Message, fileURLOverride: URL? = nil) throws {
    let item = try voiceItem(for: message)
    let fileURL = try resolvedVoiceURL(for: message, fileURLOverride: fileURLOverride)

    stop()

    #if os(iOS)
    try configureAudioSessionIfNeeded()
    #endif

    let player = try AVAudioPlayer(contentsOf: fileURL)
    player.delegate = self
    player.prepareToPlay()
    guard player.play() else {
      throw SharedAudioPlayerError.missingLocalFile
    }

    audioPlayer = player
    state = SharedAudioPlayerState(
      item: item,
      isPlaying: true,
      currentTime: player.currentTime,
      duration: player.duration
    )
    startProgressTimer()
  }

  public func pause() {
    audioPlayer?.pause()
    progressTimer?.invalidate()
    progressTimer = nil
    if let audioPlayer {
      state.currentTime = audioPlayer.currentTime
      state.duration = audioPlayer.duration
    }
    state.isPlaying = false
  }

  public func stop() {
    progressTimer?.invalidate()
    progressTimer = nil
    audioPlayer?.stop()
    audioPlayer = nil
    state = SharedAudioPlayerState()
  }

  public func seekVoice(to progress: Double, for message: Message) {
    guard isCurrentVoice(message), let audioPlayer else { return }
    let clampedProgress = min(max(progress, 0), 1)
    audioPlayer.currentTime = audioPlayer.duration * clampedProgress
    state.currentTime = audioPlayer.currentTime
    state.duration = audioPlayer.duration
  }

  public func isCurrentVoice(_ message: Message) -> Bool {
    guard let currentItem = state.item else { return false }
    guard let voice = message.voiceContent else { return false }

    return currentItem.kind == .voice &&
      currentItem.chatId == message.chatId &&
      currentItem.messageId == message.messageId &&
      currentItem.mediaId == voice.voiceID
  }

  public func playbackProgress(for message: Message) -> Double {
    guard isCurrentVoice(message), state.duration > 0 else { return 0 }
    return min(max(state.currentTime / state.duration, 0), 1)
  }

  public nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully _: Bool) {
    let duration = player.duration

    Task { @MainActor [weak self] in
      guard let self else { return }
      progressTimer?.invalidate()
      progressTimer = nil

      state.currentTime = duration
      state.duration = duration
      state.isPlaying = false
    }
  }

  private func resumeOrRestartVoicePlayback(for message: Message, fileURLOverride: URL?) throws {
    let item = try? voiceItem(for: message)
    if let audioPlayer, let item, state.item == item {
      if audioPlayer.play() {
        state.isPlaying = true
        startProgressTimer()
        return
      }
    }

    try playVoice(for: message, fileURLOverride: fileURLOverride)
  }

  private func startProgressTimer() {
    progressTimer?.invalidate()
    progressTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
      Task { @MainActor [weak self] in
        self?.syncPlaybackState()
      }
    }
  }

  private func syncPlaybackState() {
    guard let audioPlayer else { return }
    state.currentTime = audioPlayer.currentTime
    state.duration = audioPlayer.duration
    state.isPlaying = audioPlayer.isPlaying
  }

  private func voiceItem(for message: Message) throws -> SharedAudioPlayerItem {
    guard let voice = message.voiceContent else {
      throw SharedAudioPlayerError.missingVoice
    }

    return SharedAudioPlayerItem(
      kind: .voice,
      chatId: message.chatId,
      messageId: message.messageId,
      mediaId: voice.voiceID
    )
  }

  private func resolvedVoiceURL(for message: Message, fileURLOverride: URL?) throws -> URL {
    if let fileURLOverride {
      return fileURLOverride
    }

    guard let localURL = message.voiceLocalURL else {
      throw SharedAudioPlayerError.missingLocalFile
    }

    return localURL
  }

  #if os(iOS)
  private func configureAudioSessionIfNeeded() throws {
    let session = AVAudioSession.sharedInstance()
    try session.setCategory(.playback, mode: .spokenAudio, options: [.defaultToSpeaker])
    try session.setActive(true)
  }
  #endif
}
