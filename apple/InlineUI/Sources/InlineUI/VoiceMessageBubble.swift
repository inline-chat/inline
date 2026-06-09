import Combine
import InlineKit
import InlineProtocol
import SwiftUI

@MainActor
public struct VoiceMessageBubble: View {
  public enum Mode {
    case bubble
    case minimal
  }

  public let message: InlineKit.Message
  public let outgoing: Bool
  public let maxWidth: CGFloat?
  public let mode: Mode

  @ObservedObject private var player = SharedAudioPlayer.shared
  @State private var downloadProgress: DownloadProgress?
  @State private var progressCancellable: AnyCancellable?

  public init(message: InlineKit.Message, outgoing: Bool, maxWidth: CGFloat? = nil, mode: Mode = .bubble) {
    self.message = message
    self.outgoing = outgoing
    self.maxWidth = maxWidth
    self.mode = mode
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

  private var innerBackground: Color {
    outgoing ? .white.opacity(0.16) : .primary.opacity(0.06)
  }

  private var primaryTint: Color {
    outgoing ? .white : .accentColor
  }

  private var secondaryTint: Color {
    outgoing ? .white.opacity(0.36) : .secondary.opacity(0.35)
  }

  private var timeTint: Color {
    outgoing ? .white.opacity(0.56) : .secondary.opacity(0.72)
  }

  private var horizontalPadding: CGFloat {
    mode == .bubble ? 8 : 0
  }

  private var verticalPadding: CGFloat {
    mode == .bubble ? 5 : 0
  }

  private var controlSpacing: CGFloat {
    mode == .bubble ? 8 : 6
  }

  private var buttonSize: CGFloat {
    mode == .bubble ? 28 : 24
  }

  private var iconSize: CGFloat {
    mode == .bubble ? 12 : 11
  }

  private var waveformHeight: CGFloat {
    mode == .bubble ? 18 : 14
  }

  private var waveformTopPadding: CGFloat {
    mode == .bubble ? 6 : 2
  }

  private var waveformBarCount: Int {
    mode == .bubble ? 48 : 42
  }

  private var isDownloading: Bool {
    guard let voiceID else { return false }
    return FileDownloader.shared.isVoiceDownloadActive(voiceId: voiceID)
  }

  private var buttonIconName: String {
    if isDownloading {
      return "xmark"
    }
    if message.voiceLocalURL != nil {
      return isPlaying ? "pause.fill" : "play.fill"
    }
    return "arrow.down"
  }

  private var buttonActionLabel: String {
    if isDownloading {
      return "Cancel download"
    }
    if message.voiceLocalURL != nil {
      return isPlaying ? "Pause voice message" : "Play voice message"
    }
    return "Download voice message"
  }

  private var timeLabel: String {
    if let downloadProgress, downloadProgress.totalBytes > 0 {
      return "\(Int((downloadProgress.progress * 100).rounded()))%"
    }
    return Self.format(duration: currentPlaybackTime)
  }

  public var body: some View {
    content
  }

  private var content: some View {
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
    .background {
      if mode == .bubble {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .fill(innerBackground)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .environment(\.layoutDirection, .leftToRight)
    .onAppear {
      bindDownloadProgressIfNeeded()
    }
    .onDisappear {
      progressCancellable?.cancel()
      progressCancellable = nil
    }
    .onChange(of: message.voiceRemoteId) { _, _ in
      bindDownloadProgressIfNeeded()
    }
  }

  @ViewBuilder
  private var primaryButton: some View {
    ZStack {
      Circle()
        .fill(outgoing ? .white.opacity(0.14) : .accentColor.opacity(0.12))
        .frame(width: buttonSize, height: buttonSize)

      if let downloadProgress, isDownloading {
        ProgressView(value: downloadProgress.progress)
          .progressViewStyle(.circular)
          .tint(primaryTint)
          .scaleEffect(0.62)
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

  private func handleSeek(_ progress: Double) {
    if !isCurrentVoice {
      guard let localURL = message.voiceLocalURL else { return }
      do {
        try player.prepareVoice(for: message, fileURLOverride: localURL)
      } catch {
        downloadProgress = .failed(id: "voice", error: error)
        return
      }
    }

    player.seekVoice(to: progress, for: message)
  }

  private func bindDownloadProgressIfNeeded() {
    guard let voiceID else { return }
    progressCancellable?.cancel()
    progressCancellable = FileDownloader.shared.voiceProgressPublisher(voiceId: voiceID)
      .sink { progress in
        if progress.totalBytes == 0, progress.error == nil {
          self.downloadProgress = nil
        } else {
          self.downloadProgress = progress
        }
      }
  }

  private func handlePrimaryAction() {
    if let localURL = message.voiceLocalURL {
      do {
        try player.toggleVoicePlayback(for: message, fileURLOverride: localURL)
      } catch {
        downloadProgress = .failed(id: "voice", error: error)
      }
      return
    }

    guard let voiceID else { return }
    if isDownloading {
      FileDownloader.shared.cancelVoiceDownload(voiceId: voiceID)
      downloadProgress = nil
      return
    }

    bindDownloadProgressIfNeeded()
    FileDownloader.shared.downloadVoice(message: message) { result in
      switch result {
      case let .success(fileURL):
        self.downloadProgress = nil
        do {
          try player.toggleVoicePlayback(for: message, fileURLOverride: fileURL)
        } catch {
          self.downloadProgress = .failed(id: "voice_\(voiceID)", error: error)
        }
      case let .failure(error):
        self.downloadProgress = .failed(id: "voice_\(voiceID)", error: error)
      }
    }
  }

  private static func format(duration: TimeInterval) -> String {
    let clamped = max(Int(duration.rounded()), 0)
    let minutes = clamped / 60
    let seconds = clamped % 60
    return String(format: "%d:%02d", minutes, seconds)
  }
}
