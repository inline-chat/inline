import InlineUI
import SwiftUI
import UIKit

@MainActor
struct ComposeVoiceInputView: View {
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @ObservedObject var viewModel: ComposeVoiceRecordingViewModel

  let onStop: @MainActor () -> Void
  let onPlay: @MainActor () -> Void
  let onDiscard: @MainActor () -> Void
  let onSend: @MainActor () -> Void
  let onSendSilently: @MainActor () -> Void

  var body: some View {
    VStack(spacing: 4) {
      if dynamicTypeSize.isAccessibilitySize {
        waveform(progress: viewModel.phase == .recording ? 1 : viewModel.playbackProgress) { progress in
          if viewModel.phase == .review { viewModel.seekPlayback(to: progress) }
        }
        durationLabel
      }
      controls
    }
    .padding(.horizontal, 4)
    .frame(maxWidth: .infinity, minHeight: ComposeView.minHeight)
    .animation(.easeInOut(duration: 0.18), value: viewModel.phase)
    .animation(.easeInOut(duration: 0.14), value: viewModel.isPlaying)
    .animation(.easeInOut(duration: 0.14), value: viewModel.isSending)
  }

  private var controls: some View {
    VoiceComposeControlsLayout {
      switch viewModel.phase {
      case .starting:
        progressIndicator
        if !dynamicTypeSize.isAccessibilitySize { waveform(progress: 0) }
        if !dynamicTypeSize.isAccessibilitySize { durationLabel.hidden() }
        reservedIconSpace

      case .recording:
        recordingIndicator
        if !dynamicTypeSize.isAccessibilitySize { waveform(progress: 1) }
        if !dynamicTypeSize.isAccessibilitySize { durationLabel }
        iconButton("stop.fill", title: "Stop recording", action: onStop)

      case .finishing:
        progressIndicator
        if !dynamicTypeSize.isAccessibilitySize { waveform(progress: 1) }
        if !dynamicTypeSize.isAccessibilitySize { durationLabel }
        reservedIconSpace

      case .review:
        if !viewModel.isSending {
          iconButton(
            "xmark",
            title: "Discard voice message",
            action: onDiscard
          )
        }
        if !dynamicTypeSize.isAccessibilitySize {
          waveform(progress: viewModel.playbackProgress) { progress in
            viewModel.seekPlayback(to: progress)
          }
        }
        if !dynamicTypeSize.isAccessibilitySize { durationLabel }
        playButton
        sendButton

      case .idle:
        EmptyView()
      }
    }
    .id(viewModel.phase)
    .transition(.opacity.combined(with: .scale(scale: 0.98)))
  }

  private var recordingIndicator: some View {
    Circle()
      .fill(Color.red)
      .scaledFrame(width: 8, height: 8)
      .scaledFrame(width: 20, height: 20, relativeTo: .caption)
      .accessibilityLabel("Recording")
  }

  private var progressIndicator: some View {
    ProgressView()
      .controlSize(.small)
      .scaledFrame(width: 20, height: 20, relativeTo: .caption)
  }

  private var durationLabel: some View {
    Text(Self.format(duration: viewModel.duration))
      .font(.caption.monospacedDigit())
      .foregroundStyle(.secondary)
      .frame(minWidth: 38, alignment: .trailing)
      .lineLimit(1)
  }

  private var sendButton: some View {
    Group {
      if viewModel.isSending {
        progressIndicator
          .transition(.opacity.combined(with: .scale(scale: 0.9)))
      } else {
        iconButton(
          "arrow.up",
          title: "Send voice message",
          isPrimary: true,
          isEnabled: viewModel.canSend,
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
      .scaledFrame(width: 30, height: 30, relativeTo: .caption)
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
    .frame(height: 36.5)
    .frame(maxWidth: .infinity)
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

/// Keep large controls in complete rows instead of compressing their symbols or timestamp.
struct VoiceComposeControlsLayout<Content: View>: View {
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @ScaledMetric(relativeTo: .caption) private var controlSize: CGFloat = 30
  @ViewBuilder var content: () -> Content

  var body: some View {
    if dynamicTypeSize.isAccessibilitySize {
      LazyVGrid(columns: [GridItem(.adaptive(minimum: controlSize), spacing: 8)], spacing: 8) {
        content()
      }
    } else {
      HStack(spacing: 8) { content() }
    }
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
    .scaledFrame(width: 30, height: 30, relativeTo: .caption)
    .contentShape(Circle())
    .disabled(!isEnabled)
    .accessibilityLabel(title)
  }

  private func performAction() {
    action()
  }
}

private struct VoiceIconButtonStyle: ButtonStyle {
  let isPrimary: Bool
  @Environment(\.isEnabled) private var isEnabled

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .scaledFont(size: 11, weight: .semibold, relativeTo: .caption)
      .foregroundStyle(isPrimary ? Color.white : Color(uiColor: .secondaryLabel))
      .scaledFrame(width: Self.visualSize, height: Self.visualSize, relativeTo: .caption)
      .contentShape(Circle())
      .background(
        Circle()
          .fill(backgroundColor)
      )
      .opacity(opacity(isPressed: configuration.isPressed))
      .animation(.easeInOut(duration: 0.14), value: configuration.isPressed)
      .animation(.easeInOut(duration: 0.14), value: isEnabled)
      .onChange(of: configuration.isPressed) { _, isPressed in
        guard isPressed, isEnabled else { return }
        VoiceHaptics.tap()
      }
  }

  private static let visualSize: CGFloat = 26

  private func opacity(isPressed: Bool) -> Double {
    guard isEnabled else { return 0.48 }
    return isPressed ? 0.55 : 1
  }

  private var backgroundColor: Color {
    if isPrimary {
      return .accentColor
    }

    return Color(uiColor: .tertiarySystemFill).opacity(0.9)
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
