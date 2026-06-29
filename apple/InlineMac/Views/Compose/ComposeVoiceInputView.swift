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
    HStack(alignment: rowAlignment, spacing: rowSpacing) {
      switch viewModel.phase {
      case .recording:
        recordingIndicator
        waveform(progress: 1)
        durationLabel
        iconButton("stop.fill", title: "Stop recording", action: onPause)

      case .review:
        iconButton("xmark", title: "Cancel", action: onCancel)
        waveform(progress: viewModel.playbackProgress) { progress in
          viewModel.seekPlayback(to: progress)
        }
        durationLabel
        iconButton(
          viewModel.isPlaying ? "pause.fill" : "play.fill",
          title: viewModel.isPlaying ? "Pause" : "Play",
          action: onPlay
        )
        iconButton("arrow.up", title: "Send voice message", isPrimary: true, action: onSend)

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
    .animation(.easeInOut(duration: 0.18), value: viewModel.phase)
    .animation(.easeInOut(duration: 0.14), value: viewModel.isPlaying)
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
    mode.voiceInputRowSpacing
  }

  private var horizontalPadding: CGFloat {
    mode.voiceInputHorizontalPadding
  }

  private var recordingIndicator: some View {
    Circle()
      .fill(Color.red)
      .frame(width: mode.voiceInputRecordingDotSize, height: mode.voiceInputRecordingDotSize)
      .frame(width: mode.voiceInputButtonSize, height: mode.voiceInputButtonSize)
      .accessibilityLabel("Recording")
  }

  private var durationLabel: some View {
    Text(Self.format(duration: viewModel.duration))
      .font((isGlass ? Font.caption2 : Font.caption).monospacedDigit())
      .foregroundStyle(.secondary)
      .frame(minWidth: isGlass ? 34 : 38, alignment: .trailing)
      .lineLimit(1)
  }

  private func waveform(progress: Double, onSeek: (@MainActor @Sendable (Double) -> Void)? = nil) -> some View {
    AudioWaveformView(
      samples: viewModel.samples,
      progress: progress,
      foreground: Color(nsColor: .secondaryLabelColor),
      background: Color(nsColor: .tertiaryLabelColor).opacity(0.45),
      targetBarCount: mode.voiceInputTargetBarCount,
      barWidth: mode.voiceInputBarWidth,
      barSpacing: mode.voiceInputBarSpacing,
      minBarHeight: 2,
      horizontalAlignment: isGlass ? .center : .leading,
      verticalAlignment: isGlass ? .center : .bottom,
      shortSamplesMode: viewModel.phase == .recording ? .padLeadingQuiet : .stretch,
      motion: viewModel.phase == .recording ? .recordingReel : .fixed,
      onSeek: onSeek
    )
    .frame(height: mode.voiceInputWaveformHeight)
    .frame(maxWidth: .infinity)
    .layoutPriority(1)
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
    Button(action: action) {
      Image(systemName: systemName)
    }
    .buttonStyle(
      VoiceIconButtonStyle(
        isPrimary: isPrimary,
        mode: mode,
        isHovering: isHovering
      )
    )
    .frame(width: mode.voiceInputButtonSize, height: mode.voiceInputButtonSize)
    .contentShape(Circle())
    .onHover { hovering in
      isHovering = hovering
    }
    .help(title)
    .accessibilityLabel(title)
  }
}

private struct VoiceIconButtonStyle: ButtonStyle {
  let isPrimary: Bool
  let mode: ComposeControlMode
  let isHovering: Bool

  @Environment(\.isEnabled) private var isEnabled

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: mode.voiceInputIconPointSize, weight: .semibold))
      .foregroundStyle(isPrimary ? Color.white : Color(nsColor: .secondaryLabelColor))
      .frame(width: mode.voiceInputButtonVisualSize, height: mode.voiceInputButtonVisualSize)
      .contentShape(Circle())
      .background {
        Circle()
          .fill(backgroundColor)
      }
      .opacity(opacity(isPressed: configuration.isPressed))
      .scaleEffect(configuration.isPressed ? 0.96 : 1)
      .animation(.easeInOut(duration: 0.12), value: configuration.isPressed)
      .animation(.easeInOut(duration: 0.12), value: isHovering)
  }

  private var backgroundColor: Color {
    if isPrimary {
      return .accentColor
    }

    if mode == .glass {
      return Color(nsColor: .separatorColor).opacity(isHovering ? 0.5 : 0.32)
    }

    return Color(nsColor: .quinaryLabel).opacity(isHovering ? 0.82 : 1)
  }

  private func opacity(isPressed: Bool) -> Double {
    guard isEnabled else { return 0.48 }
    return isPressed ? 0.62 : 1
  }
}
