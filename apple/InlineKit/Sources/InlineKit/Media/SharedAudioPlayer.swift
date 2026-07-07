import Combine
import Foundation
import GRDB
@_exported import InlineAudioPlayback
import Logger
import Observation

public typealias SharedAudioPlayerItem = AudioPlaybackItem
public typealias SharedAudioPlayerDisplay = AudioPlaybackDisplay
public typealias SharedAudioPlayerOpenTarget = AudioPlaybackOpenTarget
public typealias SharedAudioPlayerPresentation = AudioPlaybackPresentation
public typealias SharedAudioPlayerState = AudioPlaybackState
public typealias SharedAudioPlayerError = AudioPlaybackError

public extension AudioPlaybackPeer {
  init(_ peer: Peer) {
    switch peer {
    case let .user(id):
      self = .user(id: id)
    case let .thread(id):
      self = .thread(id: id)
    }
  }

  var inlinePeer: Peer {
    switch self {
    case let .user(id):
      .user(id: id)
    case let .thread(id):
      .thread(id: id)
    }
  }
}

/// InlineKit facade over the reusable `InlineAudioPlayback` module.
///
/// This keeps existing voice-message call sites stable while the playback
/// state, timing, speed, volume, and AVFoundation ownership live in the shared
/// target for future iOS and generic document-audio reuse.
@MainActor
public final class SharedAudioPlayer: ObservableObject {
  public static let shared = SharedAudioPlayer()

  @Published public private(set) var state: SharedAudioPlayerState

  private let center: AudioPlaybackCenter
  private let log = Log.scoped("SharedAudioPlayer")

  private init(center: AudioPlaybackCenter = .shared) {
    self.center = center
    state = center.state
    observeCenter()
  }

  public func toggleVoicePlayback(
    for message: Message,
    fileURLOverride: URL? = nil,
    presentation: SharedAudioPlayerPresentation? = nil
  ) throws {
    let item = try voiceItem(for: message)

    if state.item == item {
      try toggleCurrentPlaybackThrowing()
      return
    }

    try playVoice(for: message, fileURLOverride: fileURLOverride, presentation: presentation)
  }

  public func playVoice(
    for message: Message,
    fileURLOverride: URL? = nil,
    presentation: SharedAudioPlayerPresentation? = nil
  ) throws {
    let item = try voiceItem(for: message)
    let fileURL = try resolvedVoiceURL(for: message, fileURLOverride: fileURLOverride)
    let presentation = presentation ?? voicePresentation(for: message)

    try center.play(fileURL: fileURL, item: item, presentation: presentation)
    syncStateFromCenter()
  }

  public func prepareVoice(
    for message: Message,
    fileURLOverride: URL? = nil,
    presentation: SharedAudioPlayerPresentation? = nil
  ) throws {
    let item = try voiceItem(for: message)
    if state.item == item {
      return
    }

    let fileURL = try resolvedVoiceURL(for: message, fileURLOverride: fileURLOverride)
    let presentation = presentation ?? voicePresentation(for: message)

    try center.prepare(fileURL: fileURL, item: item, presentation: presentation)
    syncStateFromCenter()
  }

  public func playAudioFile(
    fileURL: URL,
    item: SharedAudioPlayerItem,
    presentation: SharedAudioPlayerPresentation
  ) throws {
    try center.play(fileURL: fileURL, item: item, presentation: presentation)
    syncStateFromCenter()
  }

  public func prepareAudioFile(
    fileURL: URL,
    item: SharedAudioPlayerItem,
    presentation: SharedAudioPlayerPresentation
  ) throws {
    try center.prepare(fileURL: fileURL, item: item, presentation: presentation)
    syncStateFromCenter()
  }

  public func pause() {
    center.pause()
    syncStateFromCenter()
  }

  public func stop() {
    center.close()
    syncStateFromCenter()
  }

  public func seekVoice(to progress: Double, for message: Message) {
    guard isCurrentVoice(message) else { return }
    center.seek(to: progress)
    syncStateFromCenter()
  }

  public func seekCurrent(to progress: Double) {
    center.seek(to: progress)
    syncStateFromCenter()
  }

  public func toggleCurrentPlayback() {
    do {
      try toggleCurrentPlaybackThrowing()
    } catch {
      log.error("Failed to toggle current audio", error: error)
    }
  }

  public func resumeCurrentPlayback() throws {
    try center.resume()
    syncStateFromCenter()
  }

  public func setPlaybackRate(_ rate: Float) {
    center.setPlaybackRate(rate)
    syncStateFromCenter()
  }

  public func setVolume(_ volume: Float) {
    center.setVolume(volume)
    syncStateFromCenter()
  }

  public func previewVolume(_ volume: Float) {
    center.previewVolume(volume)
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

  private func toggleCurrentPlaybackThrowing() throws {
    if state.isPlaying {
      center.pause()
    } else {
      try center.resume()
    }
    syncStateFromCenter()
  }

  private func syncStateFromCenter() {
    state = center.state
  }

  private func observeCenter() {
    withObservationTracking {
      _ = center.state
    } onChange: { [weak self] in
      Task { @MainActor [weak self] in
        guard let self else { return }
        state = center.state
        observeCenter()
      }
    }
  }

  private func voicePresentation(for message: Message) -> SharedAudioPlayerPresentation {
    let senderName = fetchUserDisplayName(id: message.fromId)
    let title = senderName.map { "Voice message from \($0)" } ?? "Voice message"
    let parentTitle = fetchPeerDisplayTitle(message.peerId)
    let subtitle = formattedDuration(seconds: message.voiceContent?.duration)

    return SharedAudioPlayerPresentation(
      display: SharedAudioPlayerDisplay(
        title: title,
        parentTitle: parentTitle,
        subtitle: subtitle
      ),
      openTarget: SharedAudioPlayerOpenTarget(
        peer: AudioPlaybackPeer(message.peerId),
        chatId: message.chatId,
        messageId: message.messageId
      )
    )
  }

  private func fetchPeerDisplayTitle(_ peer: Peer) -> String? {
    switch peer {
    case let .user(id):
      fetchUserDisplayName(id: id)
    case let .thread(id):
      fetchChatTitle(id: id)
    }
  }

  private func fetchUserDisplayName(id: Int64) -> String? {
    do {
      return try AppDatabase.shared.dbWriter.read { db in
        try User
          .filter(Column("id") == id)
          .fetchOne(db)?
          .displayName
      }
    } catch {
      log.error("Failed to fetch audio playback user title", error: error)
      return nil
    }
  }

  private func fetchChatTitle(id: Int64) -> String? {
    do {
      return try AppDatabase.shared.dbWriter.read { db in
        try Chat
          .filter(Column("id") == id)
          .fetchOne(db)?
          .humanReadableTitle
      }
    } catch {
      log.error("Failed to fetch audio playback chat title", error: error)
      return nil
    }
  }

  private func formattedDuration(seconds: Int32?) -> String? {
    guard let seconds, seconds > 0 else { return nil }
    let minutes = Int(seconds) / 60
    let remainder = Int(seconds) % 60
    return String(format: "%d:%02d", minutes, remainder)
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
}
