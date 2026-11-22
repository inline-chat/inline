import Foundation
import InlineKit
import SwiftUI

public enum ComposeActionAnimationKind: Equatable, Sendable {
  case working
  case typing
  case sending(SendingActivityGlyph.Kind)
  case recordingVoice
}

public extension SendingActivityGlyph.Kind {
  init?(_ action: ApiComposeAction) {
    switch action {
    case .uploadingPhoto: self = .photo
    case .uploadingVideo: self = .video
    case .uploadingDocument: self = .file
    default: return nil
    }
  }
}

public enum ComposeActionAnimationInventory {
  public static func animation(for action: ApiComposeAction) -> ComposeActionAnimationKind? {
    switch action {
    case .working:
      .working
    case .typing:
      .typing
    case .uploadingPhoto:
      .sending(.photo)
    case .uploadingVideo:
      .sending(.video)
    case .uploadingDocument:
      .sending(.file)
    case .recordingVoice:
      .recordingVoice
    @unknown default:
      nil
    }
  }
}

@available(iOS 17.0, *)
public struct ComposeActionActivityIndicator: View {
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
    case .working:
      WorkingActivityIndicator(color: color)
    case .typing:
      TypingActivityIndicator(
        dotSize: 3,
        spacing: 2,
        color: color,
        lift: 1.8
      )
    case let .sending(kind):
      SendingActivityIndicator(kind: kind, color: color)
    case .recordingVoice:
      VoiceRecordingActivityIndicator(
        barWidth: 2.2,
        spacing: 2.2,
        minBarHeight: 4,
        maxBarHeight: 11,
        color: color
      )
    case nil:
      EmptyView()
    }
  }
}

public struct WorkingActivityIndicator: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  private let color: Color
  private let cycleDuration: TimeInterval = 0.8

  public init(color: Color = .accentColor) {
    self.color = color
  }

  // Driven by the clock, not a repeating animation: a repeatForever transaction also captures
  // layout changes around the view, which makes the spinner bounce between positions.
  public var body: some View {
    TimelineView(.animation(paused: reduceMotion)) { context in
      Circle()
        .trim(from: 0.16, to: 0.86)
        .stroke(color, style: StrokeStyle(lineWidth: 1.25, lineCap: .round))
        .padding(0.625)
        .rotationEffect(.degrees(degrees(at: context.date)))
        .transaction { $0.animation = nil }
    }
    .frame(width: 10, height: 10)
    .accessibilityHidden(true)
  }

  private func degrees(at date: Date) -> Double {
    let elapsed = date.timeIntervalSinceReferenceDate
    return elapsed.truncatingRemainder(dividingBy: cycleDuration) / cycleDuration * 360
  }
}

@available(iOS 17.0, *)
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
    .frame(width: 16, height: 12)
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
        .frame(width: 16, height: 12)
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

/// "Sending photo / video / file": a small drawn object that animates the send.
/// The drawing lives in `SendingActivityGlyph`, shared with AppKit.
@available(iOS 17.0, *)
public struct SendingActivityIndicator: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  private let kind: SendingActivityGlyph.Kind
  private let color: Color
  private let size: CGSize

  public init(
    kind: SendingActivityGlyph.Kind,
    color: Color = .accentColor,
    size: CGSize = SendingActivityGlyph.designSize
  ) {
    self.kind = kind
    self.color = color
    self.size = size
  }

  public init?(action: ApiComposeAction, color: Color = .accentColor, size: CGSize = SendingActivityGlyph.designSize) {
    guard let kind = SendingActivityGlyph.Kind(action) else { return nil }
    self.init(kind: kind, color: color, size: size)
  }

  public var body: some View {
    // Clock-driven like the other indicators, so every copy on screen is in phase
    // and layout transactions around the view can't bend the animation.
    TimelineView(.animation(paused: reduceMotion)) { context in
      let time = reduceMotion
        ? SendingActivityGlyph.restingTime(for: kind)
        : context.date.timeIntervalSinceReferenceDate
      Canvas { graphics, canvasSize in
        let resolved = color.resolve(in: graphics.environment).cgColor
        graphics.withCGContext { cgContext in
          SendingActivityGlyph.draw(
            kind,
            in: cgContext,
            rect: CGRect(origin: .zero, size: canvasSize),
            time: time,
            color: resolved
          )
        }
      }
      .transaction { $0.animation = nil }
    }
    .frame(width: size.width, height: size.height)
    .accessibilityHidden(true)
  }
}
