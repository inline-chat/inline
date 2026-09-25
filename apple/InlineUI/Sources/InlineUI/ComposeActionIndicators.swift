import Foundation
import InlineKit
import SwiftUI

public enum ComposeActionAnimationKind: Equatable, Sendable {
  case typing
  case upload
  case recordingVoice
}

public enum ComposeActionAnimationInventory {
  public static func animation(for action: ApiComposeAction) -> ComposeActionAnimationKind? {
    switch action {
    case .typing:
      .typing
    case .uploadingPhoto, .uploadingDocument, .uploadingVideo:
      .upload
    case .recordingVoice:
      .recordingVoice
    @unknown default:
      nil
    }
  }
}

public struct ComposeActionActivityIndicator: View {
  @ScaledMetric(relativeTo: .body) private var dynamicScale: CGFloat = 1
  private var scale: CGFloat {
    #if os(iOS)
    dynamicScale
    #else
    1
    #endif
  }
  private let action: ApiComposeAction
  private let color: Color

  public init(
    action: ApiComposeAction,
    color: Color = .accentColor
  ) {
    self.action = action
    self.color = color
  }

  @ViewBuilder
  public var body: some View {
    switch ComposeActionAnimationInventory.animation(for: action) {
    case .typing:
      TypingActivityIndicator(
        dotSize: 3 * scale,
        spacing: 2 * scale,
        color: color,
        lift: 1.8 * scale
      )
    case .upload:
      UploadActivityIndicator(
        width: 14 * scale,
        height: 4 * scale,
        color: color
      )
    case .recordingVoice:
      VoiceRecordingActivityIndicator(
        barWidth: 2.2 * scale,
        spacing: 2.2 * scale,
        minBarHeight: 4 * scale,
        maxBarHeight: 11 * scale,
        color: color
      )
    case nil:
      EmptyView()
    }
  }
}

@MainActor
public struct ComposeActionCompactAccessory: View {
  private let reservesSpaceWhenInactive: Bool
  @State private var activityState: ComposeActionActivityState

  public init(peer: Peer, reservesSpaceWhenInactive: Bool = true) {
    self.reservesSpaceWhenInactive = reservesSpaceWhenInactive
    _activityState = State(initialValue: ComposeActions.shared.activityState(for: peer))
  }

  @ViewBuilder
  public var body: some View {
    if reservesSpaceWhenInactive {
      reservedAccessory
    } else {
      collapsibleAccessory
    }
  }

  private var reservedAccessory: some View {
    ZStack {
      if let presentation = visiblePresentation {
        indicator(for: presentation)
      }
    }
    .scaledFrame(width: 16, height: 12)
    .clipped()
    .animation(.easeInOut(duration: 0.18), value: visiblePresentation)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(Text(visiblePresentation?.text ?? ""))
    .accessibilityHidden(visiblePresentation == nil)
  }

  @ViewBuilder
  private var collapsibleAccessory: some View {
    if let presentation = visiblePresentation {
      indicator(for: presentation)
        .scaledFrame(width: 16, height: 12)
        .clipped()
        .animation(.easeInOut(duration: 0.18), value: visiblePresentation)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(presentation.text))
    }
  }

  private func indicator(for presentation: ComposeActionPresentation) -> some View {
    ComposeActionActivityIndicator(
      action: presentation.action,
      color: .accentColor
    )
    .id("activity-\(presentation.action.rawValue)")
    .transition(.opacity.combined(with: .offset(y: 2)))
  }

  private var visiblePresentation: ComposeActionPresentation? {
    guard let presentation = activityState.presentation,
          ComposeActionAnimationInventory.animation(for: presentation.action) != nil
    else { return nil }
    return presentation
  }
}

public struct TypingActivityIndicator: View {
  private let dotSize: CGFloat
  private let spacing: CGFloat
  private let color: Color
  private let cycleDuration: TimeInterval
  private let lift: CGFloat
  private let minOpacity: Double
  private let maxOpacity: Double

  public init(
    dotSize: CGFloat = 3,
    spacing: CGFloat = 2,
    color: Color = .accentColor,
    cycleDuration: TimeInterval = 0.74,
    lift: CGFloat = 1.8,
    minOpacity: Double = 0.42,
    maxOpacity: Double = 1
  ) {
    self.dotSize = dotSize
    self.spacing = spacing
    self.color = color
    self.cycleDuration = cycleDuration
    self.lift = lift
    self.minOpacity = minOpacity
    self.maxOpacity = maxOpacity
  }

  public var body: some View {
    let reservedHeight = dotSize + lift

    TimelineView(.animation) { context in
      HStack(alignment: .bottom, spacing: spacing) {
        ForEach(0 ..< 3, id: \.self) { index in
          let pulse = Self.pulse(
            time: context.date.timeIntervalSinceReferenceDate,
            index: index,
            cycleDuration: cycleDuration
          )
          let offset = lift * CGFloat(pulse)

          Circle()
            .fill(color)
            .frame(width: dotSize, height: dotSize)
            .opacity(minOpacity + (maxOpacity - minOpacity) * pulse)
            .offset(y: -offset)
        }
      }
      .frame(height: reservedHeight, alignment: .bottom)
    }
    .frame(height: reservedHeight, alignment: .bottom)
    .accessibilityHidden(true)
  }

  private static func pulse(time: TimeInterval, index: Int, cycleDuration: TimeInterval) -> Double {
    let duration = max(cycleDuration, 0.01)
    let phase = normalizedPhase(time / duration)
    let localPhase = phase - Double(index) * 0.13
    let activeDuration = 0.62
    guard localPhase >= 0, localPhase <= activeDuration else { return 0 }

    let progress = localPhase / activeDuration
    let peak = 0.42
    if progress <= peak {
      return easeInOutCubic(progress / peak)
    }

    return 1 - easeInOutCubic((progress - peak) / (1 - peak))
  }

  private static func normalizedPhase(_ phase: Double) -> Double {
    let wrapped = phase.truncatingRemainder(dividingBy: 1)
    return wrapped >= 0 ? wrapped : wrapped + 1
  }

  private static func easeInOutCubic(_ value: Double) -> Double {
    let clamped = min(max(value, 0), 1)
    if clamped < 0.5 {
      return 4 * clamped * clamped * clamped
    }

    return 1 - pow(-2 * clamped + 2, 3) / 2
  }
}

public struct VoiceRecordingActivityIndicator: View {
  private let barWidth: CGFloat
  private let spacing: CGFloat
  private let minBarHeight: CGFloat
  private let maxBarHeight: CGFloat
  private let color: Color
  private let cycleDuration: TimeInterval
  private let minOpacity: Double
  private let maxOpacity: Double

  public init(
    barWidth: CGFloat = 2.5,
    spacing: CGFloat = 2.5,
    minBarHeight: CGFloat = 4,
    maxBarHeight: CGFloat = 11,
    color: Color = .accentColor,
    cycleDuration: TimeInterval = 0.74,
    minOpacity: Double = 0.46,
    maxOpacity: Double = 1
  ) {
    self.barWidth = barWidth
    self.spacing = spacing
    self.minBarHeight = minBarHeight
    self.maxBarHeight = max(maxBarHeight, minBarHeight)
    self.color = color
    self.cycleDuration = cycleDuration
    self.minOpacity = minOpacity
    self.maxOpacity = maxOpacity
  }

  public var body: some View {
    TimelineView(.animation) { context in
      HStack(alignment: .center, spacing: spacing) {
        ForEach(0 ..< 3, id: \.self) { index in
          let pulse = Self.pulse(
            time: context.date.timeIntervalSinceReferenceDate,
            index: index,
            cycleDuration: cycleDuration
          )
          let height = minBarHeight + (maxBarHeight - minBarHeight) * CGFloat(pulse)

          RoundedRectangle(cornerRadius: barWidth / 2, style: .continuous)
            .fill(color.opacity(minOpacity + (maxOpacity - minOpacity) * pulse))
            .frame(width: barWidth, height: height)
        }
      }
      .frame(height: maxBarHeight, alignment: .center)
    }
    .frame(height: maxBarHeight, alignment: .center)
    .accessibilityHidden(true)
  }

  private static func pulse(time: TimeInterval, index: Int, cycleDuration: TimeInterval) -> Double {
    let duration = max(cycleDuration, 0.01)
    let phase = normalizedPhase((time / duration) - Double(index) / 3)
    let raw = 0.5 - 0.5 * cos(phase * 2 * .pi)
    return smootherstep(raw)
  }

  private static func normalizedPhase(_ phase: Double) -> Double {
    let wrapped = phase.truncatingRemainder(dividingBy: 1)
    return wrapped >= 0 ? wrapped : wrapped + 1
  }

  private static func smootherstep(_ value: Double) -> Double {
    let clamped = min(max(value, 0), 1)
    return clamped * clamped * clamped * (clamped * (clamped * 6 - 15) + 10)
  }
}

public struct UploadActivityIndicator: View {
  private let width: CGFloat
  private let height: CGFloat
  private let color: Color
  private let cycleDuration: TimeInterval

  public init(
    width: CGFloat = 14,
    height: CGFloat = 4,
    color: Color = .accentColor,
    cycleDuration: TimeInterval = 1.5
  ) {
    self.width = width
    self.height = height
    self.color = color
    self.cycleDuration = cycleDuration
  }

  public var body: some View {
    TimelineView(.animation) { context in
      let phase = Self.normalizedPhase(
        context.date.timeIntervalSinceReferenceDate / max(cycleDuration, 0.01)
      )
      let fillProgress = phase <= 0.5 ? phase * 2 : (1 - phase) * 2
      let fillWidth = width * fillProgress
      let fillOffset = phase <= 0.5 ? 0 : width - fillWidth

      ZStack(alignment: .leading) {
        RoundedRectangle(cornerRadius: height / 2, style: .continuous)
          .fill(color.opacity(0.2))

        RoundedRectangle(cornerRadius: height / 2, style: .continuous)
          .fill(color.opacity(0.72))
          .frame(width: fillWidth)
          .offset(x: fillOffset)
      }
    }
    .frame(width: width, height: height)
    .accessibilityHidden(true)
  }

  private static func normalizedPhase(_ phase: Double) -> Double {
    let wrapped = phase.truncatingRemainder(dividingBy: 1)
    return wrapped >= 0 ? wrapped : wrapped + 1
  }
}
