import InlineKit
import InlineUI
import SwiftUI

@MainActor
struct ComposeVoiceInputView: View {
  @ObservedObject var viewModel: ComposeVoiceRecordingViewModel

  let onPause: @MainActor () -> Void
  let onPlay: @MainActor () -> Void
  let onCancel: @MainActor () -> Void
  let onSend: @MainActor () -> Void

  var body: some View {
    if ExperimentalFeatureFlags.voiceMessagesEnabled {
      HStack(spacing: 10) {
        switch viewModel.phase {
        case .recording:
          recordingIndicator
          waveform(progress: 1)
          durationLabel
          iconButton("pause.fill", title: "Pause recording", action: onPause)

        case .review:
          iconButton(
            viewModel.isPlaying ? "pause.fill" : "play.fill",
            title: viewModel.isPlaying ? "Pause" : "Play",
            action: onPlay
          )
          waveform(progress: viewModel.playbackProgress) { progress in
            viewModel.seekPlayback(to: progress)
          }
          durationLabel
          iconButton("xmark", title: "Cancel", action: onCancel)
          iconButton("arrow.up", title: "Send", isPrimary: true, action: onSend)

        case .idle:
          EmptyView()
        }
      }
      .padding(.horizontal, 4)
      .frame(maxWidth: .infinity, minHeight: Theme.composeMinHeight, maxHeight: Theme.composeMinHeight)
    }
  }

  private var recordingIndicator: some View {
    Circle()
      .fill(Color.red)
      .frame(width: 8, height: 8)
      .accessibilityLabel("Recording")
  }

  private var durationLabel: some View {
    Text(Self.format(duration: viewModel.duration))
      .font(.caption.monospacedDigit())
      .foregroundStyle(.secondary)
      .frame(minWidth: 38, alignment: .trailing)
  }

  private func waveform(progress: Double, onSeek: (@MainActor @Sendable (Double) -> Void)? = nil) -> some View {
    AudioWaveformView(
      samples: viewModel.samples,
      progress: progress,
      foreground: .accentColor,
      background: Color(nsColor: .tertiaryLabelColor).opacity(0.35),
      targetBarCount: 160,
      barWidth: 2,
      barSpacing: 2,
      minBarHeight: 3,
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

  @State private var isHovering = false

  var body: some View {
    Image(systemName: systemName)
      .font(.system(size: 13, weight: .semibold))
      .foregroundStyle(isPrimary ? Color.white : Color.primary)
      .frame(width: Theme.composeButtonSize, height: Theme.composeButtonSize)
      .background(
        Circle()
          .fill(backgroundColor)
      )
      .contentShape(Circle())
      .scaleEffect(isHovering ? 0.96 : 1)
      .onTapGesture(perform: action)
      .onHover { hovering in
        isHovering = hovering
      }
      .help(title)
      .accessibilityLabel(title)
      .accessibilityAddTraits(.isButton)
  }

  private var backgroundColor: Color {
    if isPrimary {
      return .accentColor
    }

    let opacity = isHovering ? 0.82 : 1
    return Color(nsColor: .quinaryLabel).opacity(opacity)
  }
}
