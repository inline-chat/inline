import SwiftUI

@MainActor
struct ComposeVoiceInputView: View {
  @ObservedObject var viewModel: ComposeVoiceRecordingViewModel

  let onStop: @MainActor () -> Void
  let onPlay: @MainActor () -> Void
  let onCancel: @MainActor () -> Void
  let onSend: @MainActor () -> Void
  let onSendSilently: @MainActor () -> Void

  var body: some View {
    HStack(spacing: 8) {
      switch viewModel.phase {
      case .starting:
        iconButton("xmark", title: "Cancel voice message", action: onCancel)
        progressIndicator
        waveform(progress: 0)
        durationLabel.hidden()
        reservedIconSpace

      case .recording:
        iconButton("xmark", title: "Cancel voice message", action: onCancel)
        recordingIndicator
        waveform(progress: 1)
        durationLabel
        iconButton("stop.fill", title: "Stop recording", action: onStop)

      case .finishing:
        iconButton("xmark", title: "Cancel voice message", action: onCancel)
        progressIndicator
        waveform(progress: 1)
        durationLabel
        reservedIconSpace

      case .review:
        iconButton(
          viewModel.isPlaying ? "pause.fill" : "play.fill",
          title: viewModel.isPlaying ? "Pause voice message" : "Play voice message",
          action: onPlay
        )
        waveform(progress: viewModel.playbackProgress) { progress in
          viewModel.seekPlayback(to: progress)
        }
        durationLabel
        iconButton("xmark", title: "Cancel voice message", action: onCancel)
        sendButton

      case .idle:
        EmptyView()
      }
    }
    .padding(.horizontal, 4)
    .frame(maxWidth: .infinity, minHeight: ComposeView.minHeight, maxHeight: ComposeView.minHeight)
  }

  private var recordingIndicator: some View {
    Circle()
      .fill(Color.red)
      .frame(width: 8, height: 8)
      .frame(width: 20, height: 20)
      .accessibilityLabel("Recording")
  }

  private var progressIndicator: some View {
    ProgressView()
      .controlSize(.small)
      .frame(width: 20, height: 20)
  }

  private var durationLabel: some View {
    Text(Self.format(duration: viewModel.duration))
      .font(.caption.monospacedDigit())
      .foregroundStyle(.secondary)
      .frame(minWidth: 38, alignment: .trailing)
      .lineLimit(1)
  }

  private var sendButton: some View {
    iconButton("arrow.up", title: "Send voice message", isPrimary: true, action: onSend)
      .contextMenu {
        Button {
          onSendSilently()
        } label: {
          Label("Send without notification", systemImage: "bell.slash")
        }
      }
  }

  private var reservedIconSpace: some View {
    Color.clear
      .frame(width: 30, height: 30)
      .accessibilityHidden(true)
  }

  private func waveform(progress: Double, onSeek: (@MainActor @Sendable (Double) -> Void)? = nil) -> some View {
    ComposeVoiceWaveformView(
      samples: viewModel.samples,
      progress: progress,
      foreground: Color(uiColor: .secondaryLabel),
      background: Color(uiColor: .tertiaryLabel).opacity(0.45),
      motion: viewModel.phase == .recording ? .recordingReel : .fixed,
      onSeek: onSeek
    )
    .frame(height: 20)
    .frame(maxWidth: .infinity)
  }

  private func iconButton(
    _ systemName: String,
    title: String,
    isPrimary: Bool = false,
    action: @escaping @MainActor () -> Void
  ) -> some View {
    VoiceIconControl(
      systemName: systemName,
      title: title,
      isPrimary: isPrimary,
      action: action
    )
  }

  private static func format(duration: TimeInterval) -> String {
    let clamped = max(Int(duration.rounded()), 0)
    let minutes = clamped / 60
    let seconds = clamped % 60
    return String(format: "%d:%02d", minutes, seconds)
  }
}

@MainActor
private struct VoiceIconControl: View {
  let systemName: String
  let title: String
  let isPrimary: Bool
  let action: @MainActor () -> Void

  var body: some View {
    Button(action: action) {
      Image(systemName: systemName)
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(isPrimary ? Color.white : Color.primary)
        .frame(width: Self.visualSize, height: Self.visualSize)
        .background(
          Circle()
            .fill(backgroundColor)
        )
        .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .frame(width: 30, height: 30)
    .contentShape(Circle())
    .accessibilityLabel(title)
  }

  private var backgroundColor: Color {
    if isPrimary {
      return .accentColor
    }

    return Color(uiColor: .quaternaryLabel).opacity(0.72)
  }

  private static let visualSize: CGFloat = 26
}
