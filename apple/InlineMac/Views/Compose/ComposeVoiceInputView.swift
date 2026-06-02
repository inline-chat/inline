import InlineKit
import SwiftUI

struct ComposeVoiceInputView: View {
  @ObservedObject var viewModel: ComposeVoiceRecordingViewModel

  let onPause: () -> Void
  let onPlay: () -> Void
  let onCancel: () -> Void
  let onSend: () -> Void

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
          waveform(progress: viewModel.playbackProgress)
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

  private func waveform(progress: Double) -> some View {
    ComposeVoiceWaveformView(
      samples: viewModel.samples,
      progress: progress,
      foreground: .accentColor,
      background: Color(nsColor: .tertiaryLabelColor).opacity(0.35)
    )
    .frame(height: 22)
    .frame(maxWidth: .infinity)
  }

  private func iconButton(
    _ systemName: String,
    title: String,
    isPrimary: Bool = false,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Image(systemName: systemName)
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(isPrimary ? Color.white : Color.primary)
        .frame(width: Theme.composeButtonSize, height: Theme.composeButtonSize)
        .background(
          Circle()
            .fill(isPrimary ? Color.accentColor : Color(nsColor: .quinaryLabel))
        )
    }
    .buttonStyle(.plain)
    .help(title)
    .accessibilityLabel(title)
  }

  private static func format(duration: TimeInterval) -> String {
    let clamped = max(Int(duration.rounded()), 0)
    let minutes = clamped / 60
    let seconds = clamped % 60
    return String(format: "%d:%02d", minutes, seconds)
  }
}

private struct ComposeVoiceWaveformView: View {
  let samples: [UInt8]
  let progress: Double
  let foreground: Color
  let background: Color

  private var bars: [CGFloat] {
    let raw = samples.map { byte -> CGFloat in
      max(0.16, CGFloat(byte) / 255)
    }

    guard !raw.isEmpty else {
      return Array(repeating: 0.32, count: 36)
    }

    let targetCount = min(48, max(24, raw.count))
    if raw.count <= targetCount {
      return raw
    }

    let chunkSize = max(1, raw.count / targetCount)
    return stride(from: 0, to: raw.count, by: chunkSize).map { index in
      let upperBound = min(index + chunkSize, raw.count)
      let chunk = raw[index ..< upperBound]
      return chunk.max() ?? 0.32
    }
  }

  var body: some View {
    GeometryReader { geometry in
      let clampedProgress = min(max(progress, 0), 1)
      let progressIndex = Int((Double(bars.count) * clampedProgress).rounded(.down))

      HStack(alignment: .center, spacing: 2) {
        ForEach(Array(bars.enumerated()), id: \.offset) { index, value in
          Capsule(style: .continuous)
            .fill(index < progressIndex ? foreground : background)
            .frame(
              maxWidth: .infinity,
              maxHeight: max(5, geometry.size.height * value)
            )
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
  }
}
