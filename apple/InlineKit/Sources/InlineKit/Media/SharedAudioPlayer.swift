import Auth
import Combine
import Foundation
import GRDB
@_exported import InlineAudioPlayback
import Logger
import Observation
#if os(iOS)
import UIKit
#endif

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
public struct VoicePlaybackLoading: Equatable, Sendable {
  public let item: AudioPlaybackItem
  public let presentation: AudioPlaybackPresentation
  public var progress: Double?
}

@MainActor
public final class SharedAudioPlayer: ObservableObject {
  public static let shared = SharedAudioPlayer()

  @Published public private(set) var state: SharedAudioPlayerState

  @Published public private(set) var loadingVoice: VoicePlaybackLoading?
  @Published public private(set) var playbackError: String?
  /// True from the play request until audio actually starts, so controls can respond at once.
  @Published public private(set) var isStartingPlayback = false

  public var isVoiceSelected: Bool { loadingVoice != nil || state.item?.kind == .voice }

  private struct PendingVoiceRequest {
    let revision: UInt64
    let account: AuthAccountMutationToken
    let item: AudioPlaybackItem
    let presentation: AudioPlaybackPresentation
  }
  private var pendingVoice: PendingVoiceRequest?
  private var intentRevision: UInt64 = 0
  private var selectedAccount: AuthAccountMutationToken?
  private var localDataMaintenanceDepth = 0
  private var progressSubscription: AnyCancellable?
  private var accountTask: Task<Void, Never>?
  private let auth: AuthHandle
  private let downloadVoice: (Message, @escaping (Result<URL, Error>) -> Void) -> Void
  private let cancelVoiceDownload: (Int64) -> Void
  private let voiceProgressPublisher: (Int64) -> AnyPublisher<DownloadProgress, Never>
  private let voicePresentationOverride: ((Message) -> AudioPlaybackPresentation)?
  private let isForeground: () -> Bool
  private let center: AudioPlaybackCenter
  private let log = Log.scoped("SharedAudioPlayer")

  init(
    center: AudioPlaybackCenter = .shared,
    auth: AuthHandle = Auth.shared.handle,
    downloadVoice: @escaping (Message, @escaping (Result<URL, Error>) -> Void) -> Void = {
      FileDownloader.shared.downloadVoice(message: $0, completion: $1)
    },
    cancelVoiceDownload: @escaping (Int64) -> Void = { FileDownloader.shared.cancelVoiceDownload(voiceId: $0) },
    voiceProgressPublisher: @escaping (Int64) -> AnyPublisher<DownloadProgress, Never> = {
      FileDownloader.shared.voiceProgressPublisher(voiceId: $0)
    },
    voicePresentation: ((Message) -> AudioPlaybackPresentation)? = nil,
    isForeground: @escaping () -> Bool = {
      #if os(iOS)
      UIApplication.shared.applicationState == .active
      #else
      true
      #endif
    }
  ) {
    self.center = center
    self.auth = auth
    self.downloadVoice = downloadVoice
    self.cancelVoiceDownload = cancelVoiceDownload
    self.voiceProgressPublisher = voiceProgressPublisher
    voicePresentationOverride = voicePresentation
    self.isForeground = isForeground
    state = center.state
    center.onUserIntent = { [weak self] in self?.invalidatePendingVoice(cancelTransfer: false) }
    center.onAudioTakeover = { [weak self] _ in self?.invalidatePendingVoice(cancelTransfer: true) }
    center.canResume = { [weak self] in
      guard let self, localDataMaintenanceDepth == 0, let account = selectedAccount else { return false }
      return (try? auth.validateAccountMutation(account)) != nil
    }
    observeCenter()
    let snapshots = auth.snapshots
    accountTask = Task { [weak self] in
      for await _ in snapshots {
        guard let self, !Task.isCancelled else { return }
        if let account = selectedAccount, (try? auth.validateAccountMutation(account)) == nil { stop() }
      }
    }
  }

  deinit { accountTask?.cancel() }

  /// The explicit selection belongs to this process adapter, never to a recyclable bubble.
  public func requestVoicePlayback(for message: Message, fileURLOverride: URL? = nil) {
    do {
      #if os(iOS)
      if let denial = InlineAudioSession.shared.voiceDenial { throw denial }
      #endif
      let account = try beginSelectionAccount()
      let item = try voiceItem(for: message)
      if let url = fileURLOverride ?? message.voiceLocalURL, FileManager.default.fileExists(atPath: url.path) {
        invalidatePendingVoice(cancelTransfer: true)
        selectedAccount = account
        try toggleVoicePlayback(for: message, fileURLOverride: url)
        return
      }
      stop()
      selectedAccount = account
      playbackError = nil
      intentRevision &+= 1
      let request = PendingVoiceRequest(revision: intentRevision, account: account, item: item,
                                        presentation: voicePresentation(for: message))
      pendingVoice = request
      loadingVoice = VoicePlaybackLoading(item: item, presentation: request.presentation, progress: nil)
      downloadVoice(message) { [weak self] result in self?.completeVoiceRequest(request, result: result) }
      guard pendingVoice?.revision == request.revision else { return }
      progressSubscription = voiceProgressPublisher(item.mediaId).sink { [weak self] progress in
        guard let self, pendingVoice?.revision == request.revision else { return }
        loadingVoice?.progress = progress.totalBytes > 0 ? progress.progress : nil
      }
    } catch { reportPlaybackError(error) }
  }

  public func cancelVoiceSelection(mediaID: Int64) {
    if pendingVoice?.item.mediaId == mediaID { stop() }
    else { cancelVoiceDownload(mediaID) }
  }

  public func clearPlaybackError() {
    center.clearPlaybackError()
    playbackError = nil
  }

  /// Balance nested cache/reset maintenance before admitting a new selection.
  public func beginLocalDataMaintenance() {
    localDataMaintenanceDepth += 1
    stop()
  }

  public func endLocalDataMaintenance() {
    if localDataMaintenanceDepth > 0 { localDataMaintenanceDepth -= 1 }
  }

  /// Navigation uses the selected voice's authority rather than the current account's fresh token.
  public func voiceNavigationAccount(for target: AudioPlaybackOpenTarget) -> AuthAccountMutationToken? {
    guard localDataMaintenanceDepth == 0, let account = selectedAccount,
          (try? auth.validateAccountMutation(account)) != nil
    else { return nil }
    if let pendingVoice, pendingVoice.item.kind == .voice,
       pendingVoice.presentation.openTarget == target { return account }
    if center.item?.kind == .voice, center.openTarget == target { return account }
    return nil
  }

  public func reportPlaybackError(_ error: Error) {
    syncStateFromCenter()
    playbackError = (error as? AudioPlaybackError)?.localizedDescription
      ?? "Couldn't play this voice message. Try again."
  }

  private func completeVoiceRequest(_ request: PendingVoiceRequest, result: Result<URL, Error>) {
    guard pendingVoice?.revision == request.revision, pendingVoice?.item == request.item,
          selectedAccount == request.account, (try? auth.validateAccountMutation(request.account)) != nil
    else { return }
    // Clear admission before explicit core calls, which themselves invalidate older intent.
    invalidatePendingVoice(cancelTransfer: false)
    switch result {
    case let .success(url):
      do {
        try center.prepare(fileURL: url, item: request.item, presentation: request.presentation)
        if isForeground() { try center.resume(completion: playbackCompletion) }
      } catch { reportPlaybackError(error) }
      syncStateFromCenter()
    case let .failure(error):
      if !FileDownloader.isCancellation(error) { reportPlaybackError(error) }
    }
  }

  private func invalidatePendingVoice(cancelTransfer: Bool) {
    let old = pendingVoice
    intentRevision &+= 1
    pendingVoice = nil
    loadingVoice = nil
    progressSubscription?.cancel()
    progressSubscription = nil
    if cancelTransfer, let old { cancelVoiceDownload(old.item.mediaId) }
  }

  private func beginSelectionAccount() throws -> AuthAccountMutationToken {
    guard localDataMaintenanceDepth == 0 else { throw AudioPlaybackError.playbackUnavailable }
    // A recycled row may still carry an old account's message/file before the auth
    // snapshot task runs. Reject that first action rather than rebinding its engine.
    if let selectedAccount, pendingVoice != nil || center.item != nil,
       (try? auth.validateAccountMutation(selectedAccount)) == nil {
      stop()
      throw AudioPlaybackError.playbackUnavailable
    }
    return try auth.beginAccountMutation()
  }

  public func toggleVoicePlayback(
    for message: Message,
    fileURLOverride: URL? = nil,
    presentation: SharedAudioPlayerPresentation? = nil
  ) throws {
    selectedAccount = try beginSelectionAccount()
    let item = try voiceItem(for: message)
    let hasDifferentSourceOverride = fileURLOverride.map { center.sourceURL != $0 } ?? false

    if center.item == item, !hasDifferentSourceOverride {
      try toggleCurrentPlaybackThrowing()
      return
    }

    let fileURL = try resolvedVoiceURL(for: message, fileURLOverride: fileURLOverride)
    let presentation = presentation ?? voicePresentation(for: message)

    try center.toggleOrPlay(fileURL: fileURL, item: item, presentation: presentation, completion: playbackCompletion)
    playbackError = center.playbackError
    syncStateFromCenter()
  }

  public func playVoice(
    for message: Message,
    fileURLOverride: URL? = nil,
    presentation: SharedAudioPlayerPresentation? = nil
  ) throws {
    selectedAccount = try beginSelectionAccount()
    let item = try voiceItem(for: message)
    let fileURL = try resolvedVoiceURL(for: message, fileURLOverride: fileURLOverride)
    let presentation = presentation ?? voicePresentation(for: message)

    try center.play(fileURL: fileURL, item: item, presentation: presentation, completion: playbackCompletion)
    playbackError = center.playbackError
    syncStateFromCenter()
  }

  public func prepareVoice(
    for message: Message,
    fileURLOverride: URL? = nil,
    presentation: SharedAudioPlayerPresentation? = nil
  ) throws {
    selectedAccount = try beginSelectionAccount()
    let item = try voiceItem(for: message)
    let fileURL = try resolvedVoiceURL(for: message, fileURLOverride: fileURLOverride)
    if center.item == item, center.sourceURL == fileURL { return }
    let presentation = presentation ?? voicePresentation(for: message)

    try center.prepare(fileURL: fileURL, item: item, presentation: presentation)
    playbackError = center.playbackError
    syncStateFromCenter()
  }

  public func playAudioFile(
    fileURL: URL,
    item: SharedAudioPlayerItem,
    presentation: SharedAudioPlayerPresentation
  ) throws {
    selectedAccount = try beginSelectionAccount()
    try center.play(fileURL: fileURL, item: item, presentation: presentation, completion: playbackCompletion)
    playbackError = center.playbackError
    syncStateFromCenter()
  }

  public func prepareAudioFile(
    fileURL: URL,
    item: SharedAudioPlayerItem,
    presentation: SharedAudioPlayerPresentation
  ) throws {
    selectedAccount = try beginSelectionAccount()
    try center.prepare(fileURL: fileURL, item: item, presentation: presentation)
    playbackError = center.playbackError
    syncStateFromCenter()
  }

  public func toggleAudioDocumentPlayback(
    for message: Message,
    document: DocumentInfo,
    fileURLOverride: URL? = nil,
    presentation: SharedAudioPlayerPresentation? = nil
  ) throws {
    selectedAccount = try beginSelectionAccount()
    let item = try audioDocumentItem(for: message, document: document)
    let hasDifferentSourceOverride = fileURLOverride.map { center.sourceURL != $0 } ?? false

    if center.item == item, !hasDifferentSourceOverride {
      try toggleCurrentPlaybackThrowing()
      return
    }

    let fileURL = try resolvedAudioDocumentURL(document, fileURLOverride: fileURLOverride)
    let presentation = presentation ?? audioDocumentPresentation(for: message, document: document)
    try center.toggleOrPlay(fileURL: fileURL, item: item, presentation: presentation, completion: playbackCompletion)
    playbackError = center.playbackError
    syncStateFromCenter()
  }

  public func pause() {
    invalidatePendingVoice(cancelTransfer: true)
    center.pause()
    syncStateFromCenter()
  }

  public func stop() {
    invalidatePendingVoice(cancelTransfer: true)
    selectedAccount = nil
    playbackError = nil
    center.close()
    syncStateFromCenter()
  }

  public func seekVoice(to progress: Double, for message: Message) {
    guard progress.isFinite else { return }
    invalidatePendingVoice(cancelTransfer: true)
    guard isCurrentVoice(message) else { return }
    center.seek(to: progress)
    syncStateFromCenter()
  }

  public func seekCurrent(to progress: Double) {
    guard progress.isFinite else { return }
    invalidatePendingVoice(cancelTransfer: true)
    center.seek(to: progress)
    syncStateFromCenter()
  }

  public func toggleCurrentPlayback() {
    do {
      try toggleCurrentPlaybackThrowing()
    } catch {
      syncStateFromCenter()
      reportPlaybackError(error)
      log.error("Failed to toggle current audio", error: error)
    }
  }

  public func resumeCurrentPlayback() throws {
    try center.resume(completion: playbackCompletion)
    playbackError = center.playbackError
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
    guard let currentItem = center.item else { return false }
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
    if center.isPlaying || center.isStarting {
      center.pause()
    } else {
      try center.resume(completion: playbackCompletion)
    }
    playbackError = center.playbackError
    syncStateFromCenter()
  }

  private func syncStateFromCenter() {
    let nextState = center.state
    if let error = center.playbackError { playbackError = error }
    else if nextState.isPlaying, !state.isPlaying { playbackError = nil }
    if isStartingPlayback != center.isStarting { isStartingPlayback = center.isStarting }
    guard state != nextState else { return }
    state = nextState
  }

  private var playbackCompletion: AudioPlaybackCenter.Completion {
    { [weak self] result in
      guard let self else { return }
      if case let .failure(error) = result, !(error is CancellationError) {
        reportPlaybackError(error)
      } else { syncStateFromCenter() }
    }
  }

  private func observeCenter() {
    withObservationTracking {
      _ = center.state
      _ = center.isStarting
      _ = center.playbackError
    } onChange: { [weak self] in
      Task { @MainActor [weak self] in
        guard let self else { return }
        syncStateFromCenter()
        observeCenter()
      }
    }
  }

  private func voicePresentation(for message: Message) -> SharedAudioPlayerPresentation {
    if let voicePresentationOverride { return voicePresentationOverride(message) }
    let sender = fetchUser(id: message.fromId)
    let senderName = sender?.displayName
    let title = senderName.map { "Voice message from \($0)" } ?? "Voice message"
    let parentTitle = fetchPeerDisplayTitle(message.peerId)
    let subtitle = formattedDuration(seconds: message.voiceContent?.duration)

    return SharedAudioPlayerPresentation(
      display: SharedAudioPlayerDisplay(
        title: title,
        parentTitle: parentTitle,
        subtitle: subtitle,
        senderName: senderName,
        artworkURL: sender?.getLocalURL()
      ),
      openTarget: SharedAudioPlayerOpenTarget(
        peer: AudioPlaybackPeer(message.peerId),
        chatId: message.chatId,
        messageId: message.messageId
      )
    )
  }

  private func audioDocumentPresentation(
    for message: Message,
    document: DocumentInfo
  ) -> SharedAudioPlayerPresentation {
    let title = MessagePreviewText.document(
      fileName: document.document.fileName,
      mimeType: document.document.mimeType,
      includesEmoji: false
    )

    return SharedAudioPlayerPresentation(
      display: SharedAudioPlayerDisplay(title: title),
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
    fetchUser(id: id)?.displayName
  }

  private func fetchUser(id: Int64) -> User? {
    do {
      return try AppDatabase.shared.dbWriter.read { db in
        try User
          .filter(Column("id") == id)
          .fetchOne(db)
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

  private func audioDocumentItem(
    for message: Message,
    document: DocumentInfo
  ) throws -> SharedAudioPlayerItem {
    guard let item = AudioDocumentSupport.playbackItem(for: message, document: document) else {
      throw SharedAudioPlayerError.unsupportedAudioFile
    }
    return item
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

  private func resolvedAudioDocumentURL(
    _ document: DocumentInfo,
    fileURLOverride: URL?
  ) throws -> URL {
    if let fileURLOverride {
      return fileURLOverride
    }

    guard let localURL = AudioDocumentSupport.localURL(for: document) else {
      throw SharedAudioPlayerError.missingLocalFile
    }

    return localURL
  }
}
