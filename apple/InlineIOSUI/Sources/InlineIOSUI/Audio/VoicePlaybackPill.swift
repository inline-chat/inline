#if os(iOS)
import InlineKit
import SwiftUI
import UIKit

/// The compact playback surface shared by chat headers and navigation roots.
public struct VoicePlaybackPill: View {
  public static let height: CGFloat = 52
  public static func preferredHeight(compatibleWith traits: UITraitCollection) -> CGFloat {
    let title = UIFontMetrics(forTextStyle: .subheadline).scaledFont(
      for: .systemFont(ofSize: 14, weight: .medium), compatibleWith: traits
    )
    let detail = UIFontMetrics(forTextStyle: .caption1).scaledFont(
      for: .systemFont(ofSize: 13), compatibleWith: traits
    )
    let accessible = traits.preferredContentSizeCategory.isAccessibilityCategory
    let titleLines: CGFloat = accessible ? 2 : 1
    let detailLines: CGFloat = accessible ? 2 : 1
    return max(height, ceil(title.lineHeight * titleLines + detail.lineHeight * detailLines + (accessible ? 66 : 12)))
  }

  @ObservedObject private var player = SharedAudioPlayer.shared
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @ScaledMetric(relativeTo: .subheadline) private var titleFontSize: CGFloat = 14
  @ScaledMetric(relativeTo: .caption) private var detailFontSize: CGFloat = 13
  private let onOpen: (AudioPlaybackOpenTarget) -> Void

  public init(onOpen: @escaping (AudioPlaybackOpenTarget) -> Void) {
    self.onOpen = onOpen
  }

  public var body: some View {
    VStack(spacing: 4) {
      if dynamicTypeSize.isAccessibilitySize {
        metadataButton
        HStack(spacing: 0) {
          playbackControl
          Spacer()
          speedMenu
          closeButton
        }
      } else {
        HStack(spacing: 0) {
          playbackControl
          metadataButton
          speedMenu
          closeButton
        }
      }
    }
    .padding(.horizontal, dynamicTypeSize.isAccessibilitySize ? 16 : 8)
    .frame(height: capsuleHeight)
    .background {
      if #available(iOS 26.0, *) {
        RoundedRectangle(cornerRadius: Self.height / 2, style: .continuous)
          .fill(.clear)
          .glassEffect(.regular, in: .rect(cornerRadius: Self.height / 2))
      } else {
        RoundedRectangle(cornerRadius: Self.height / 2, style: .continuous).fill(.thinMaterial)
      }
    }
    .overlay(alignment: .bottom) {
      GeometryReader { geometry in
        Rectangle()
          .fill(.tint.opacity(0.55))
          .frame(width: geometry.size.width * progress, height: 2)
      }
      .frame(height: 2)
      .padding(.horizontal, Self.height / 2)
      .padding(.bottom, 2)
      .environment(\.layoutDirection, .leftToRight)
      .allowsHitTesting(false)
      .accessibilityHidden(true)
    }
    .clipShape(.rect(cornerRadius: Self.height / 2))
  }

  private var metadataButton: some View {
    Button {
      if let openTarget {
        onOpen(openTarget)
      }
    } label: {
      VStack(alignment: .leading, spacing: 2) {
        Text(display?.senderName ?? "Voice message")
          .font(.system(size: titleFontSize, weight: .medium))
          .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
          .foregroundStyle(.primary)

        if dynamicTypeSize.isAccessibilitySize {
          if let context {
            Text(verbatim: context)
              .lineLimit(1)
          }
          statusLabel
        } else {
          HStack(spacing: 4) {
            if let context {
              Text(verbatim: context)
                .lineLimit(1)
              Text("·")
            }
            statusLabel
              .fixedSize(horizontal: true, vertical: false)
          }
        }
      }
      .font(.system(size: detailFontSize))
      .foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, alignment: .leading)
      .frame(minHeight: 44)
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .disabled(openTarget == nil)
    .accessibilityLabel(
      "Voice message from \(display?.senderName ?? "Unknown sender") in \(display?.parentTitle ?? "chat")"
    )
    .accessibilityValue(player
      .loadingVoice != nil ? "Downloading" :
      "\(timeLabel(player.state.currentTime)) of \(timeLabel(player.state.duration))")
    .accessibilityHint("Opens the original message")
  }

  private var speedMenu: some View {
    Menu {
      ForEach([Float(0.75), 1, 1.25, 1.5, 2], id: \.self) { rate in
        Button {
          player.setPlaybackRate(rate)
        } label: {
          if player.state.playbackRate == rate {
            Label(rateLabel(rate), systemImage: "checkmark")
          } else {
            Text(verbatim: rateLabel(rate))
          }
        }
      }
    } label: {
      Text(verbatim: rateLabel)
        .font(.system(size: 13, weight: .semibold))
        .monospacedDigit()
        .frame(width: 44, height: 44)
        .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Playback speed")
    .accessibilityValue(rateLabel)
    .accessibilityHint("Choose a playback speed")
  }

  private var closeButton: some View {
    Button { player.stop() } label: {
      Image(systemName: "xmark")
        .font(.system(size: 13))
        .foregroundStyle(.secondary)
        .frame(width: 44, height: 44)
        .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Close voice playback")
  }

  private var capsuleHeight: CGFloat {
    let titleLines: CGFloat = dynamicTypeSize.isAccessibilitySize ? 2 : 1
    let detailLines: CGFloat = dynamicTypeSize.isAccessibilitySize ? 2 : 1
    return max(Self.height, ceil(
      UIFont.systemFont(ofSize: titleFontSize, weight: .medium).lineHeight * titleLines
        + UIFont.systemFont(ofSize: detailFontSize).lineHeight * detailLines
        + (dynamicTypeSize.isAccessibilitySize ? 66 : 12)
    ))
  }

  private var progress: Double {
    if let loading = player.loadingVoice {
      return min(max(loading.progress ?? 0, 0), 1)
    }
    guard player.state.duration > 0 else { return 0 }
    return min(max(player.state.currentTime / player.state.duration, 0), 1)
  }

  @ViewBuilder
  private var playbackControl: some View {
    if let loading = player.loadingVoice {
      Group {
        if let progress = loading.progress {
          ZStack {
            Circle().stroke(.secondary.opacity(0.25), lineWidth: 2)
            Circle()
              .trim(from: 0, to: min(max(progress, 0), 1))
              .stroke(.tint, style: StrokeStyle(lineWidth: 2, lineCap: .round))
              .rotationEffect(.degrees(-90))
          }
          .frame(width: 18, height: 18)
        } else {
          ProgressView()
        }
      }
      .frame(width: 44, height: 44)
      .accessibilityLabel("Downloading voice message")
    } else {
      Button { player.toggleCurrentPlayback() } label: {
        Image(systemName: player.state.isPlaying ? "pause.fill" : "play.fill")
          .font(.system(size: 17))
          .frame(width: 44, height: 44)
          .contentShape(.rect)
      }
      .buttonStyle(.plain)
      .accessibilityLabel(player.state.isPlaying ? "Pause voice message" : "Play voice message")
    }
  }

  private var display: AudioPlaybackDisplay? {
    player.loadingVoice?.presentation.display ?? player.state.display
  }

  private var openTarget: AudioPlaybackOpenTarget? {
    if let loading = player.loadingVoice {
      return loading.presentation.openTarget
    }
    return player.state.openTarget
  }

  private var context: String? {
    guard let context = display?.parentTitle, !context.isEmpty else { return nil }
    return context
  }

  private var statusLabel: some View {
    Text(verbatim: statusText)
      .monospacedDigit()
      .lineLimit(1)
      .environment(\.layoutDirection, .leftToRight)
  }

  private var statusText: String {
    if let loading = player.loadingVoice {
      if let progress = loading.progress {
        return "Downloading \(Int(min(max(progress, 0), 1) * 100))%"
      }
      return "Downloading…"
    }
    return "\(timeLabel(player.state.currentTime)) / \(timeLabel(player.state.duration))"
  }

  private var rateLabel: String {
    rateLabel(player.state.playbackRate)
  }

  private func rateLabel(_ rate: Float) -> String {
    rate == rate.rounded() ? "\(Int(rate))×" : "\(rate)×"
  }

  private func timeLabel(_ seconds: TimeInterval) -> String {
    let wholeSeconds = Int(max(seconds.isFinite ? seconds : 0, 0))
    return String(format: "%d:%02d", wholeSeconds / 60, wholeSeconds % 60)
  }
}
#endif
