import InlineKit
import InlineUI
import SwiftUI

@MainActor
struct ComposeVoiceInputView: View {
  @ObservedObject var viewModel: ComposeVoiceRecordingViewModel

  let mode: ComposeControlMode
  let onPause: @MainActor () -> Void
  let onPlay: @MainActor () -> Void
  let onCancel: @MainActor () -> Void
  let onSend: @MainActor () -> Void

  init(
    viewModel: ComposeVoiceRecordingViewModel,
    mode: ComposeControlMode = .legacy,
    onPause: @escaping @MainActor () -> Void,
    onPlay: @escaping @MainActor () -> Void,
    onCancel: @escaping @MainActor () -> Void,
    onSend: @escaping @MainActor () -> Void
  ) {
    self.viewModel = viewModel
    self.mode = mode
    self.onPause = onPause
    self.onPlay = onPlay
    self.onCancel = onCancel
    self.onSend = onSend
  }

  var body: some View {
    if ExperimentalFeatureFlags.voiceMessagesEnabled {
      HStack(alignment: rowAlignment, spacing: rowSpacing) {
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
      .padding(.horizontal, horizontalPadding)
      .frame(
        maxWidth: .infinity,
        minHeight: mode.textMinHeight,
        maxHeight: mode.textMinHeight,
        alignment: rowFrameAlignment
      )
    }
  }

  private var isGlass: Bool {
    mode == .glass
  }

  private var rowAlignment: VerticalAlignment {
    isGlass ? .center : .bottom
  }

  private var rowFrameAlignment: Alignment {
    isGlass ? .center : .bottom
  }

  private var rowSpacing: CGFloat {
    isGlass ? 6 : 10
  }

  private var horizontalPadding: CGFloat {
    isGlass ? 2 : 4
  }

  private var recordingIndicator: some View {
    Circle()
      .fill(Color.red)
      .frame(width: isGlass ? 6 : 8, height: isGlass ? 6 : 8)
      .accessibilityLabel("Recording")
  }

  private var durationLabel: some View {
    Text(Self.format(duration: viewModel.duration))
      .font((isGlass ? Font.caption2 : Font.caption).monospacedDigit())
      .foregroundStyle(.secondary)
      .frame(minWidth: isGlass ? 30 : 38, alignment: .trailing)
  }

  private func waveform(progress: Double, onSeek: (@MainActor @Sendable (Double) -> Void)? = nil) -> some View {
    AudioWaveformView(
      samples: viewModel.samples,
      progress: progress,
      foreground: Color(nsColor: .secondaryLabelColor),
      background: Color(nsColor: .tertiaryLabelColor).opacity(0.45),
      targetBarCount: isGlass ? 96 : 160,
      barWidth: isGlass ? 1 : 1.5,
      barSpacing: isGlass ? 1.5 : 2,
      minBarHeight: 2,
      verticalAlignment: isGlass ? .center : .bottom,
      shortSamplesMode: viewModel.phase == .recording ? .padLeadingQuiet : .stretch,
      motion: viewModel.phase == .recording ? .recordingReel : .fixed,
      onSeek: onSeek
    )
    .frame(height: isGlass ? 14 : 20)
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
      mode: mode,
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
  let mode: ComposeControlMode
  let action: @MainActor () -> Void

  @State private var isHovering = false

  var body: some View {
    Image(systemName: systemName)
      .font(.system(size: mode.voiceInputIconPointSize, weight: .medium))
      .foregroundStyle(isPrimary ? Color.white : Color.primary)
      .frame(width: mode.voiceInputButtonSize, height: mode.voiceInputButtonSize)
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
