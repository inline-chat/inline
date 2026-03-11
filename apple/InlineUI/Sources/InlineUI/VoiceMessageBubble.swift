import Combine
import InlineKit
import InlineProtocol
import SwiftUI

@MainActor
public struct VoiceMessageBubble: View {
  public let message: InlineKit.Message
  public let outgoing: Bool

  @ObservedObject private var player = SharedAudioPlayer.shared
  @State private var downloadProgress: DownloadProgress?
  @State private var progressCancellable: AnyCancellable?

  public init(message: InlineKit.Message, outgoing: Bool) {
    self.message = message
    self.outgoing = outgoing
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

  private var timeLabel: String {
    if let downloadProgress, downloadProgress.totalBytes > 0 {
      return "\(Int((downloadProgress.progress * 100).rounded()))%"
    }
    return Self.format(duration: currentPlaybackTime)
  }

  public var body: some View {
    HStack(spacing: 10) {
      primaryButton

      VStack(alignment: .leading, spacing: 6) {
        VoiceWaveformView(
          waveform: voice?.waveform ?? Data(),
          progress: playbackProgress,
          foreground: primaryTint,
          background: secondaryTint
        )
        .frame(height: 22)

        Text(timeLabel)
          .font(.caption.monospacedDigit())
          .foregroundStyle(outgoing ? .white.opacity(0.8) : .secondary)
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
    .background(
      RoundedRectangle(cornerRadius: 18, style: .continuous)
        .fill(innerBackground)
    )
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
    Button(action: handlePrimaryAction) {
      ZStack {
        Circle()
          .fill(outgoing ? .white.opacity(0.14) : .accentColor.opacity(0.12))
          .frame(width: 34, height: 34)

        if let downloadProgress, isDownloading {
          ProgressView(value: downloadProgress.progress)
            .progressViewStyle(.circular)
            .tint(primaryTint)
            .scaleEffect(0.7)
        } else {
          Image(systemName: buttonIconName)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(primaryTint)
        }
      }
    }
    .buttonStyle(.plain)
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

private struct VoiceWaveformView: View {
  let waveform: Data
  let progress: Double
  let foreground: Color
  let background: Color

  private var samples: [CGFloat] {
    let raw = waveform.map { byte -> CGFloat in
      let normalized = CGFloat(byte) / 255
      return max(0.16, normalized)
    }

    guard !raw.isEmpty else {
      return Array(repeating: 0.35, count: 28)
    }

    let targetCount = min(36, max(16, raw.count))
    if raw.count <= targetCount {
      return raw
    }

    let chunkSize = max(1, raw.count / targetCount)
    return stride(from: 0, to: raw.count, by: chunkSize).map { index in
      let upperBound = min(index + chunkSize, raw.count)
      let chunk = raw[index ..< upperBound]
      return chunk.max() ?? 0.35
    }
  }

  var body: some View {
    GeometryReader { geometry in
      let progressIndex = Int((Double(samples.count) * min(max(progress, 0), 1)).rounded(.down))
      HStack(alignment: .center, spacing: 2) {
        ForEach(Array(samples.enumerated()), id: \.offset) { index, value in
          Capsule(style: .continuous)
            .fill(index < progressIndex ? foreground : background)
            .frame(
              maxWidth: .infinity,
              maxHeight: max(6, geometry.size.height * value)
            )
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
  }
}
