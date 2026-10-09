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

  private static let rates: [Float] = [0.75, 1, 1.25, 1.5, 2]
  /// Tapping the speed badge steps through the common rates; the menu offers all of them.
  private static let quickRates: [Float] = [1, 1.5, 2]
  private static let cornerRadius = height / 2

  @ObservedObject private var player = SharedAudioPlayer.shared
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @ScaledMetric(relativeTo: .subheadline) private var titleFontSize: CGFloat = 14
  @ScaledMetric(relativeTo: .caption) private var detailFontSize: CGFloat = 13
  /// The last selected item, kept so a closing pill fades out with its content intact.
  @State private var lastContent: Snapshot?
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
    .padding(.horizontal, dynamicTypeSize.isAccessibilitySize ? 16 : 4)
    .frame(height: capsuleHeight)
    .overlay(alignment: .bottom) { progressLine }
    .contentShape(.rect(cornerRadius: Self.cornerRadius))
    .modifier(PillSurface(cornerRadius: Self.cornerRadius))
    .onChange(of: liveContent, initial: true) { _, content in
      if let content { lastContent = content }
    }
  }

  private var progressLine: some View {
    GeometryReader { geometry in
      Capsule()
        .fill(.tint)
        .frame(width: geometry.size.width * progress, height: 2)
        .animation(reduceMotion ? nil : .linear(duration: 0.12), value: progress)
    }
    .frame(height: 2)
    // Stay on the flat part of the capsule's bottom edge.
    .padding(.horizontal, Self.cornerRadius)
    .padding(.bottom, 2)
    .opacity(0.7)
    .environment(\.layoutDirection, .leftToRight)
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }

  private var metadataButton: some View {
    Button {
      if let openTarget = content.openTarget {
        onOpen(openTarget)
      }
    } label: {
      VStack(alignment: .leading, spacing: 2) {
        Text(content.display?.senderName ?? "Voice message")
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
      .padding(.leading, 2)
      .frame(maxWidth: .infinity, alignment: .leading)
      .frame(minHeight: 44)
      .contentShape(.rect)
    }
    .buttonStyle(PillControlButtonStyle(pressedScale: 1))
    .disabled(content.openTarget == nil)
    .accessibilityLabel(
      "Voice message from \(content.display?.senderName ?? "Unknown sender") in \(content.display?.parentTitle ?? "chat")"
    )
    .accessibilityValue(
      content.isLoading
        ? "Downloading"
        : "\(timeLabel(content.currentTime)) of \(timeLabel(content.duration))"
    )
    .accessibilityHint("Opens the original message")
  }

  private var speedMenu: some View {
    let rate = player.state.playbackRate
    let isBoosted = rate != 1
    return Menu {
      Picker("Playback Speed", selection: Binding(
        get: { rate },
        set: { player.setPlaybackRate($0) }
      )) {
        ForEach(Self.rates, id: \.self) { rate in
          Text(verbatim: rateLabel(rate)).tag(rate)
        }
      }
      .pickerStyle(.inline)
    } label: {
      Text(verbatim: rateLabel(rate))
        .font(.system(size: 12, weight: .bold, design: .rounded))
        .monospacedDigit()
        .contentTransition(.numericText(value: Double(rate)))
        .foregroundStyle(isBoosted ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
        .padding(.horizontal, 6)
        .frame(minWidth: 30, minHeight: 22)
        .background {
          RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(isBoosted ? AnyShapeStyle(.tint.opacity(0.16)) : AnyShapeStyle(.quaternary))
        }
        .frame(minWidth: 44, minHeight: 44)
        .contentShape(.rect)
        .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: rate)
    } primaryAction: {
      player.setPlaybackRate(Self.quickRates.first { $0 > rate } ?? 1)
    }
    .buttonStyle(.plain)
    .sensoryFeedback(.selection, trigger: rate)
    .accessibilityLabel("Playback speed")
    .accessibilityValue(rateLabel(rate))
    .accessibilityHint("Changes the speed. Touch and hold for all speeds")
  }

  private var closeButton: some View {
    Button { player.stop() } label: {
      Image(systemName: "xmark")
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(.secondary)
        .frame(width: 44, height: 44)
        .contentShape(.rect)
    }
    .buttonStyle(PillControlButtonStyle())
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
    let content = content
    if content.isLoading {
      return min(max(content.loadingProgress ?? 0, 0), 1)
    }
    guard content.duration > 0 else { return 0 }
    return min(max(content.currentTime / content.duration, 0), 1)
  }

  private var playbackControl: some View {
    let content = content
    return ZStack {
      if content.isLoading {
        Group {
          if let progress = content.loadingProgress {
            ZStack {
              Circle().stroke(.secondary.opacity(0.25), lineWidth: 2)
              Circle()
                .trim(from: 0, to: min(max(progress, 0), 1))
                .stroke(.tint, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(reduceMotion ? nil : .linear(duration: 0.15), value: progress)
            }
            .frame(width: 18, height: 18)
          } else {
            ProgressView()
          }
        }
        .frame(width: 44, height: 44)
        .transition(.scale(scale: 0.6).combined(with: .opacity))
        .accessibilityLabel("Downloading voice message")
      } else {
        Button { player.toggleCurrentPlayback() } label: {
          Image(systemName: content.isPlaying ? "pause.fill" : "play.fill")
            .font(.system(size: 18, weight: .semibold))
            .contentTransition(
              reduceMotion ? .identity : .symbolEffect(.replace.magic(fallback: .downUp.byLayer), options: .speed(1.4))
            )
            .frame(width: 44, height: 44)
            .contentShape(.rect)
        }
        .buttonStyle(PillControlButtonStyle())
        .transition(.scale(scale: 0.6).combined(with: .opacity))
        .accessibilityLabel(content.isPlaying ? "Pause voice message" : "Play voice message")
      }
    }
    .animation(reduceMotion ? nil : .snappy(duration: 0.22), value: content.isLoading)
    .animation(reduceMotion ? nil : .snappy(duration: 0.22), value: content.isPlaying)
  }

  /// Everything the pill renders for the selected voice message.
  private struct Snapshot: Equatable {
    var display: AudioPlaybackDisplay?
    var openTarget: AudioPlaybackOpenTarget?
    var isLoading = false
    var loadingProgress: Double?
    var isPlaying = false
    var currentTime: TimeInterval = 0
    var duration: TimeInterval = 0
  }

  private var liveContent: Snapshot? {
    if let loading = player.loadingVoice {
      return Snapshot(
        display: loading.presentation.display,
        openTarget: loading.presentation.openTarget,
        isLoading: true,
        loadingProgress: loading.progress
      )
    }
    let state = player.state
    guard state.item?.kind == .voice else { return nil }
    return Snapshot(
      display: state.display,
      openTarget: state.openTarget,
      isPlaying: state.isPlaying || player.isStartingPlayback,
      currentTime: state.currentTime,
      duration: state.duration
    )
  }

  private var content: Snapshot {
    liveContent ?? lastContent ?? Snapshot()
  }

  private var context: String? {
    guard let context = content.display?.parentTitle, !context.isEmpty else { return nil }
    return context
  }

  private var statusLabel: some View {
    Text(verbatim: statusText)
      .monospacedDigit()
      .lineLimit(1)
      .environment(\.layoutDirection, .leftToRight)
  }

  private var statusText: String {
    let content = content
    if content.isLoading {
      if let progress = content.loadingProgress {
        return "Downloading \(Int(min(max(progress, 0), 1) * 100))%"
      }
      return "Downloading…"
    }
    return "\(timeLabel(content.currentTime)) / \(timeLabel(content.duration))"
  }

  private func rateLabel(_ rate: Float) -> String {
    rate == rate.rounded() ? "\(Int(rate))×" : "\(rate)×"
  }

  private func timeLabel(_ seconds: TimeInterval) -> String {
    let wholeSeconds = Int(max(seconds.isFinite ? seconds : 0, 0))
    return String(format: "%d:%02d", wholeSeconds / 60, wholeSeconds % 60)
  }
}

/// Liquid Glass that reacts to touch where available, material elsewhere.
private struct PillSurface: ViewModifier {
  let cornerRadius: CGFloat

  func body(content: Content) -> some View {
    if #available(iOS 26.0, *) {
      content.glassEffect(.regular.interactive(), in: .rect(cornerRadius: cornerRadius))
    } else {
      content.background(.thinMaterial, in: .rect(cornerRadius: cornerRadius, style: .continuous))
    }
  }
}

private struct PillControlButtonStyle: ButtonStyle {
  var pressedScale: CGFloat = 0.86
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .opacity(configuration.isPressed ? 0.5 : 1)
      .scaleEffect(configuration.isPressed && !reduceMotion ? pressedScale : 1)
      .animation(.snappy(duration: 0.18), value: configuration.isPressed)
  }
}
#endif
