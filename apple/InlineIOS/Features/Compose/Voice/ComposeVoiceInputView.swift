import SwiftUI
import UIKit

@MainActor
struct ComposeVoiceInputView: View {
  @ObservedObject var viewModel: ComposeVoiceRecordingViewModel

  let onStop: @MainActor () -> Void
  let onPlay: @MainActor () -> Void
  let onDiscard: @MainActor () -> Void
  let onSend: @MainActor () -> Void
  let onSendSilently: @MainActor () -> Void

  var body: some View {
    controls
      .frame(maxWidth: .infinity, minHeight: ComposeView.minHeight, maxHeight: ComposeView.minHeight)
      .animation(.easeInOut(duration: 0.18), value: viewModel.phase)
      .animation(.easeInOut(duration: 0.14), value: viewModel.isPlaying)
      .animation(.easeInOut(duration: 0.14), value: viewModel.isSending)
      .animation(.easeInOut(duration: 0.14), value: viewModel.isFinalizingForSend)
  }

  private var controls: some View {
    HStack(spacing: 0) {
      switch viewModel.phase {
      case .starting:
        discardButton
        progressIndicator
        waveform(progress: 0)
        durationLabel.hidden()
        iconButton("stop.fill", title: "Stop recording", isEnabled: false, action: onStop)
        iconButton("arrow.up", title: "Send voice message", isPrimary: true, isEnabled: false, action: onSend)

      case .recording:
        discardButton
        waveform(progress: 1)
        durationLabel
        iconButton("stop.fill", title: "Stop recording", action: onStop)
        sendButton

      case .finishing:
        discardButton
        progressIndicator
        waveform(progress: 1)
        durationLabel
        reservedIconSpace
        if viewModel.isFinalizingForSend {
          sendProgressIndicator
        } else {
          reservedIconSpace
        }

      case .review:
        if !viewModel.isSending {
          discardButton
        }
        waveform(progress: viewModel.playbackProgress) { progress in
          viewModel.seekPlayback(to: progress)
        }
        durationLabel
        playButton
        sendButton

      case .idle:
        EmptyView()
      }
    }
    .id(viewModel.phase)
    .transition(.opacity.combined(with: .scale(scale: 0.98)))
  }

  private var progressIndicator: some View {
    ProgressView()
      .controlSize(.small)
      .frame(width: VoiceControlMetrics.hitSize, height: VoiceControlMetrics.hitSize)
  }

  private var durationLabel: some View {
    Text(Self.format(duration: viewModel.duration))
      .font(.subheadline.monospacedDigit())
      .foregroundStyle(viewModel.phase == .recording ? .primary : .secondary)
      .lineLimit(1)
      .fixedSize()
      .frame(minWidth: VoiceControlMetrics.hitSize)
      .padding(.trailing, 4)
  }

  private var discardButton: some View {
    iconButton("xmark", title: "Discard voice message", action: onDiscard)
  }

  private var sendProgressIndicator: some View {
    progressIndicator
      .transition(.opacity.combined(with: .scale(scale: 0.9)))
  }

  private var sendButton: some View {
    Group {
      if viewModel.isSending {
        sendProgressIndicator
      } else {
        iconButton(
          "arrow.up",
          title: "Send voice message",
          isPrimary: true,
          isEnabled: viewModel.canSend || viewModel.phase == .recording,
          action: onSend
        )
          .contextMenu {
            Button {
              onSendSilently()
            } label: {
              Label("Send without notification", systemImage: "bell.slash")
            }
          }
      }
    }
  }

  private var playButton: some View {
    iconButton(
      viewModel.isPlaying ? "pause.fill" : "play.fill",
      title: viewModel.isPlaying ? "Pause voice message" : "Play voice message",
      isEnabled: !viewModel.isSending,
      action: onPlay
    )
  }

  private var reservedIconSpace: some View {
    Color.clear
      .frame(width: VoiceControlMetrics.hitSize, height: VoiceControlMetrics.hitSize)
      .accessibilityHidden(true)
  }

  private func waveform(progress: Double, onSeek: (@MainActor @Sendable (Double) -> Void)? = nil) -> some View {
    ComposeVoiceWaveformView(
      samples: viewModel.samples,
      progress: progress,
      foreground: Color(uiColor: .label).opacity(0.88),
      background: viewModel.phase == .recording
        ? Color(uiColor: .label).opacity(0.88)
        : Color(uiColor: .secondaryLabel).opacity(0.72),
      motion: viewModel.phase == .recording ? .recordingReel : .fixed,
      onSeek: onSeek
    )
    .frame(height: 30)
    .frame(maxWidth: .infinity)
    .padding(.horizontal, 4)
  }

  private func iconButton(
    _ systemName: String,
    title: String,
    isPrimary: Bool = false,
    isEnabled: Bool = true,
    action: @escaping @MainActor () -> Void
  ) -> some View {
    VoiceIconControl(
      systemName: systemName,
      title: title,
      isPrimary: isPrimary,
      isEnabled: isEnabled,
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
  let isEnabled: Bool
  let action: @MainActor () -> Void

  var body: some View {
    Button(action: performAction) {
      Image(systemName: systemName)
    }
    .buttonStyle(VoiceIconButtonStyle(isPrimary: isPrimary))
    .disabled(!isEnabled)
    .accessibilityLabel(title)
  }

  private func performAction() {
    action()
  }
}

private enum VoiceControlMetrics {
  /// Apple's minimum comfortable touch target.
  static let hitSize: CGFloat = 44
  /// Matches the compose send button so the primary control does not jump when recording starts.
  static let visualSize: CGFloat = 32
}

/// Filled circle matching the compose send button, with a full 44pt hit area.
private struct VoiceIconButtonStyle: ButtonStyle {
  let isPrimary: Bool
  @Environment(\.isEnabled) private var isEnabled

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: 14, weight: isPrimary ? .bold : .semibold))
      .foregroundStyle(isPrimary ? Color.white : Color(uiColor: .label))
      .frame(width: VoiceControlMetrics.visualSize, height: VoiceControlMetrics.visualSize)
      .background(Circle().fill(backgroundColor))
      .scaleEffect(configuration.isPressed ? 0.9 : 1)
      .opacity(isEnabled ? 1 : 0.45)
      .frame(width: VoiceControlMetrics.hitSize, height: VoiceControlMetrics.hitSize)
      .contentShape(Rectangle())
      .animation(.easeInOut(duration: 0.14), value: configuration.isPressed)
      .animation(.easeInOut(duration: 0.14), value: isEnabled)
      .onChange(of: configuration.isPressed) { _, isPressed in
        guard isPressed, isEnabled else { return }
        VoiceHaptics.tap()
      }
  }

  private var backgroundColor: Color {
    isPrimary
      ? Color(uiColor: ThemeManager.shared.selected.accent)
      : Color(uiColor: .tertiarySystemFill)
  }
}

@MainActor
private enum VoiceHaptics {
  static func tap() {
    let generator = UIImpactFeedbackGenerator(style: .light)
    generator.prepare()
    generator.impactOccurred(intensity: 0.85)
  }
}
