import Combine
import Foundation
import InlineKit
import InlineProtocol
import SwiftUI

@MainActor
public struct VoiceMessageBubble: View {
  public enum Mode {
    /// A single Messages-style row (glyph, centered waveform, duration) drawn straight on the
    /// message bubble.
    case bubble
    case embeddedBubble
    case minimal
  }

  /// Height of the `.bubble` row.
  public static let bubbleHeight: CGFloat = 28

  /// Width of the `.bubble` row, growing with the memo's length like Messages does.
  public static func preferredBubbleWidth(duration: Int32) -> CGFloat {
    min(132 + CGFloat(max(duration, 0)) * 6, 240)
  }

  public let message: InlineKit.Message
  public let outgoing: Bool
  public let maxWidth: CGFloat?
  public let mode: Mode
  public let accentColor: Color

  @ObservedObject private var player = SharedAudioPlayer.shared
  @State private var downloadProgress: DownloadProgress?
  @State private var downloadedLocalURL: URL?
  @State private var progressCancellable: AnyCancellable?
  @State private var autoDownloadRequestedVoiceID: Int64?
  @State private var downloadRevision = UUID()

  public init(
    message: InlineKit.Message,
    outgoing: Bool,
    maxWidth: CGFloat? = nil,
    mode: Mode = .bubble,
    accentColor: Color = .accentColor
  ) {
    self.message = message
    self.outgoing = outgoing
    self.maxWidth = maxWidth
    self.mode = mode
    self.accentColor = accentColor
  }

  private var voice: Client_MessageVoiceContent? {
    message.voiceContent
  }

  private var voiceID: Int64? {
    message.voiceRemoteId
  }

  private var isCurrentVoice: Bool {
    player.isCurrentVoice(message)
  }

  private var isPlaying: Bool {
    isCurrentVoice && player.state.isPlaying
  }

  private var playbackProgress: Double {
    isCurrentVoice ? player.playbackProgress(for: message) : 0
  }

  private var currentPlaybackTime: TimeInterval {
    if isCurrentVoice {
      player.state.currentTime
    } else {
      TimeInterval(voice?.duration ?? 0)
    }
  }

  private var usesBubbleMetrics: Bool {
    mode != .minimal
  }

  private var primaryTint: Color {
    if mode == .bubble {
      return outgoing ? .white : .primary
    }
    return outgoing ? .white : accentColor
  }

  private var secondaryTint: Color {
    if mode == .bubble {
      return outgoing ? .white.opacity(0.45) : .secondary.opacity(0.4)
    }
    return outgoing ? .white.opacity(0.36) : .secondary.opacity(0.35)
  }

  private var timeTint: Color {
    if mode == .bubble {
      return outgoing ? .white.opacity(0.9) : .secondary
    }
    return outgoing ? .white.opacity(0.56) : .secondary.opacity(0.72)
  }

  private var horizontalPadding: CGFloat {
    usesBubbleMetrics ? 8 : 0
  }

  private var verticalPadding: CGFloat {
    usesBubbleMetrics ? 5 : 0
  }

  private var controlSpacing: CGFloat {
    usesBubbleMetrics ? 8 : 6
  }

  private var buttonSize: CGFloat {
    usesBubbleMetrics ? 28 : 24
  }

  private var iconSize: CGFloat {
    usesBubbleMetrics ? 12 : 11
  }

  private var waveformHeight: CGFloat {
    usesBubbleMetrics ? 18 : 14
  }

  private var waveformTopPadding: CGFloat {
    usesBubbleMetrics ? 6 : 2
  }

  private var waveformBarCount: Int {
    usesBubbleMetrics ? 48 : 42
  }

  private var isDownloading: Bool {
    // Cache publication can make the file playable before download finalization finishes.
    guard localURL == nil, let voiceID else { return false }
    return FileDownloader.shared.isVoiceDownloadActive(voiceId: voiceID)
  }

  private var localURL: URL? {
    existingFileURL(downloadedLocalURL) ?? existingFileURL(message.voiceLocalURL)
  }

  private var downloadID: String {
    if let voiceID {
      return "voice_\(voiceID)"
    }
    return "voice_\(message.messageId)"
  }

  private var visibleDownloadProgress: DownloadProgress? {
    guard let downloadProgress, isDownloading, downloadProgress.error == nil else { return nil }
    return downloadProgress.isComplete ? nil : downloadProgress
  }

  private var hasDownloadError: Bool {
    guard let error = downloadProgress?.error else { return false }
    return !Self.isCancellation(error)
  }

  private var buttonIconName: String {
    if localURL != nil {
      return isPlaying ? "pause.fill" : "play.fill"
    }
    if isDownloading {
      return "xmark"
    }
    if hasDownloadError {
      return "arrow.clockwise"
    }
    return "arrow.down"
  }

  private var buttonActionLabel: String {
    if localURL != nil {
      return isPlaying ? "Pause voice message" : "Play voice message"
    }
    if isDownloading {
      return "Cancel download"
    }
    if hasDownloadError {
      return "Retry voice message download"
    }
    return "Download voice message"
  }

  private var timeLabel: String {
    if hasDownloadError {
      return "Failed"
    }
    if let downloadProgress = visibleDownloadProgress, downloadProgress.totalBytes > 0 {
      return "\(Int((downloadProgress.progress * 100).rounded()))%"
    }
    return Self.format(duration: currentPlaybackTime)
  }

  public var body: some View {
    content
  }

  @ViewBuilder
  private var layout: some View {
    if mode == .bubble {
      bubbleLayout
    } else {
      compactLayout
    }
  }

  private var bubbleLayout: some View {
    HStack(spacing: 10) {
      bubbleGlyph

      AudioWaveformView(
        waveform: voice?.waveform ?? Data(),
        progress: playbackProgress,
        foreground: primaryTint,
        background: secondaryTint,
        targetBarCount: 64,
        barWidth: 2.5,
        barSpacing: 2,
        minBarHeight: 2.5,
        verticalAlignment: .center,
        onSeek: handleSeek
      )
      .frame(height: 22)

      Text(timeLabel)
        .font(.footnote.monospacedDigit())
        .foregroundStyle(timeTint)
        .fixedSize()
    }
    .frame(height: Self.bubbleHeight)
    .frame(maxWidth: maxWidth, alignment: .leading)
  }

  private var compactLayout: some View {
    HStack(spacing: controlSpacing) {
      primaryButton

      VStack(alignment: .leading, spacing: 1) {
        AudioWaveformView(
          waveform: voice?.waveform ?? Data(),
          progress: playbackProgress,
          foreground: primaryTint,
          background: secondaryTint,
          targetBarCount: waveformBarCount,
          barWidth: 1.5,
          barSpacing: 2,
          minBarHeight: 2,
          verticalAlignment: .bottom,
          onSeek: handleSeek
        )
        .frame(height: waveformHeight)
        .padding(.top, waveformTopPadding)

        Text(timeLabel)
          .font(.caption2.monospacedDigit())
          .foregroundStyle(timeTint)
      }
    }
    .padding(.horizontal, horizontalPadding)
    .padding(.vertical, verticalPadding)
    .frame(maxWidth: maxWidth, alignment: .leading)
  }

  private var content: some View {
    layout
    .frame(maxWidth: .infinity, alignment: .leading)
    .environment(\.layoutDirection, .leftToRight)
    .onAppear {
      refreshLocalURLFromMessage()
      bindDownloadProgressIfNeeded()
      requestAutoDownloadIfNeeded()
    }
    .onDisappear {
      progressCancellable?.cancel()
      progressCancellable = nil
    }
    .onChange(of: message.voiceRemoteId) { oldID, _ in
      if oldID != message.voiceRemoteId {
        downloadRevision = UUID()
        downloadedLocalURL = nil
        downloadProgress = nil
        autoDownloadRequestedVoiceID = nil
      }
      refreshLocalURLFromMessage()
      bindDownloadProgressIfNeeded()
      requestAutoDownloadIfNeeded()
    }
    .onChange(of: message.voiceLocalRelativePath) { _, _ in
      refreshLocalURLFromMessage()
      if localURL != nil {
        downloadProgress = nil
      }
      requestAutoDownloadIfNeeded()
    }
  }

  @ViewBuilder
  private var primaryButton: some View {
    ZStack {
      Circle()
        .fill(outgoing ? .white.opacity(0.14) : accentColor.opacity(0.12))
        .frame(width: buttonSize, height: buttonSize)

      if let downloadProgress = visibleDownloadProgress {
        Circle()
          .trim(from: 0, to: max(0.04, downloadProgress.progress))
          .stroke(primaryTint, style: StrokeStyle(lineWidth: 2, lineCap: .round))
          .rotationEffect(.degrees(-90))
          .frame(width: buttonSize - 7, height: buttonSize - 7)

        Image(systemName: "xmark")
          .font(.system(size: iconSize - 1, weight: .bold))
          .foregroundStyle(primaryTint)
      } else {
        Image(systemName: buttonIconName)
          .font(.system(size: iconSize, weight: .semibold))
          .foregroundStyle(primaryTint)
      }
    }
    .contentShape(Circle())
    .onTapGesture(perform: handlePrimaryAction)
    .help(buttonActionLabel)
    .accessibilityLabel(buttonActionLabel)
    .accessibilityAddTraits(.isButton)
  }

  /// A bare glyph with no button chrome, as in Messages.
  @ViewBuilder
  private var bubbleGlyph: some View {
    ZStack {
      if let downloadProgress = visibleDownloadProgress {
        Circle()
          .stroke(secondaryTint, lineWidth: 2)
          .frame(width: 20, height: 20)

        Circle()
          .trim(from: 0, to: max(0.04, downloadProgress.progress))
          .stroke(primaryTint, style: StrokeStyle(lineWidth: 2, lineCap: .round))
          .rotationEffect(.degrees(-90))
          .frame(width: 20, height: 20)

        Image(systemName: "xmark")
          .font(.system(size: 8, weight: .bold))
          .foregroundStyle(primaryTint)
      } else {
        Image(systemName: buttonIconName)
          .font(.system(size: 17, weight: .semibold))
          .foregroundStyle(primaryTint)
          .contentTransition(.symbolEffect(.replace))
      }
    }
    .frame(width: 22, height: Self.bubbleHeight)
    // The glyph is small; reach into the bubble padding so it's still easy to hit.
    .contentShape(Rectangle().inset(by: -8))
    .onTapGesture(perform: handlePrimaryAction)
    .help(buttonActionLabel)
    .accessibilityLabel(buttonActionLabel)
    .accessibilityAddTraits(.isButton)
  }

  private func handleSeek(_ progress: Double) {
    if !isCurrentVoice {
      guard let localURL else { return }
      do {
        try player.prepareVoice(for: message, fileURLOverride: localURL)
      } catch {
        #if os(iOS)
        player.reportPlaybackError(error)
        #else
        downloadProgress = .failed(id: downloadID, error: error)
        #endif
        return
      }
    }

    player.seekVoice(to: progress, for: message)
  }

  private func bindDownloadProgressIfNeeded() {
    progressCancellable?.cancel()

    guard let voiceID else {
      downloadProgress = nil
      return
    }

    if let progress = FileDownloader.shared.currentVoiceProgress(voiceId: voiceID) {
      applyDownloadProgress(progress)
    }

    progressCancellable = FileDownloader.shared.voiceProgressPublisher(voiceId: voiceID)
      .sink { progress in
        self.applyDownloadProgress(progress)
      }
  }

  private func handlePrimaryAction() {
    #if os(iOS)
    if localURL == nil, let voiceID, isDownloading {
      player.cancelVoiceSelection(mediaID: voiceID)
      downloadProgress = nil
      return
    }
    player.requestVoicePlayback(for: message, fileURLOverride: localURL)
    #else
    if let localURL {
      do {
        try player.toggleVoicePlayback(for: message, fileURLOverride: localURL)
      } catch {
        downloadProgress = .failed(id: downloadID, error: error)
      }
      return
    }

    guard let voiceID else { return }
    if isDownloading {
      FileDownloader.shared.cancelVoiceDownload(voiceId: voiceID)
      downloadProgress = nil
      return
    }

    startDownload(autoplay: true, showErrors: true)
    #endif
  }

  private func requestAutoDownloadIfNeeded() {
    guard let voiceID, let voice else { return }
    guard localURL == nil, !isDownloading else { return }
    guard autoDownloadRequestedVoiceID != voiceID else { return }
    guard AutoDownloadPolicy.shouldDownload(kind: .voice, sizeBytes: voice.size > 0 ? voice.size : nil) else {
      return
    }

    autoDownloadRequestedVoiceID = voiceID
    startDownload(autoplay: false, showErrors: false)
  }

  private func startDownload(autoplay: Bool, showErrors: Bool) {
    guard let voiceID else { return }

    bindDownloadProgressIfNeeded()
    let revision = downloadRevision
    FileDownloader.shared.downloadVoice(message: message) { result in
      guard self.downloadRevision == revision else { return }
      switch result {
      case let .success(fileURL):
        self.downloadedLocalURL = fileURL
        self.downloadProgress = nil
        guard autoplay else { return }
        do {
          try player.toggleVoicePlayback(for: message, fileURLOverride: fileURL)
        } catch {
          self.downloadProgress = .failed(id: "voice_\(voiceID)", error: error)
        }
      case let .failure(error):
        if Self.isCancellation(error) {
          self.downloadProgress = nil
        } else {
          self.downloadProgress = showErrors ? .failed(id: "voice_\(voiceID)", error: error) : nil
        }
      }
    }
  }

  private func applyDownloadProgress(_ progress: DownloadProgress) {
    guard progress.id == downloadID else { return }
    if localURL != nil {
      downloadProgress = nil
      return
    }
    if progress.isCancellation {
      downloadProgress = nil
      return
    }
    if progress.error != nil {
      downloadProgress = progress
      return
    }
    if isDownloading, progress.totalBytes > 0 {
      downloadProgress = progress
      return
    }
    downloadProgress = nil
  }

  private func refreshLocalURLFromMessage() {
    if downloadedLocalURL == nil, let messageURL = existingFileURL(message.voiceLocalURL) {
      downloadedLocalURL = messageURL
    } else if existingFileURL(downloadedLocalURL) == nil {
      downloadedLocalURL = nil
    }
  }

  private func existingFileURL(_ url: URL?) -> URL? {
    guard let url, FileManager.default.fileExists(atPath: url.path) else { return nil }
    return url
  }

  private static func format(duration: TimeInterval) -> String {
    let clamped = max(Int(duration.rounded()), 0)
    let minutes = clamped / 60
    let seconds = clamped % 60
    return String(format: "%d:%02d", minutes, seconds)
  }

  private static func isCancellation(_ error: Error) -> Bool {
    (error as NSError).code == NSURLErrorCancelled
  }
}
