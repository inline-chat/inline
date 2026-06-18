import Foundation
import SwiftUI

@MainActor
public struct AudioWaveformView: View {
  public enum HorizontalBarsAlignment {
    case leading
    case center
  }

  public enum VerticalBarsAlignment {
    case center
    case bottom
  }

  public enum ShortSamplesMode {
    case stretch
    case padLeadingQuiet
  }

  public enum Motion {
    case fixed
    case recordingReel
  }

  private let samples: [UInt8]
  private let progress: Double
  private let foreground: Color
  private let background: Color
  private let targetBarCount: Int
  private let barWidth: CGFloat
  private let barSpacing: CGFloat
  private let minBarHeight: CGFloat
  private let horizontalAlignment: HorizontalBarsAlignment
  private let verticalAlignment: VerticalBarsAlignment
  private let shortSamplesMode: ShortSamplesMode
  private let motion: Motion
  private let onSeek: (@MainActor @Sendable (Double) -> Void)?

  public init(
    samples: [UInt8],
    progress: Double,
    foreground: Color,
    background: Color,
    targetBarCount: Int = 48,
    barWidth: CGFloat = 2,
    barSpacing: CGFloat = 2,
    minBarHeight: CGFloat = 3,
    horizontalAlignment: HorizontalBarsAlignment = .leading,
    verticalAlignment: VerticalBarsAlignment = .center,
    shortSamplesMode: ShortSamplesMode = .stretch,
    motion: Motion = .fixed,
    onSeek: (@MainActor @Sendable (Double) -> Void)? = nil
  ) {
    self.samples = samples
    self.progress = progress
    self.foreground = foreground
    self.background = background
    self.targetBarCount = targetBarCount
    self.barWidth = barWidth
    self.barSpacing = barSpacing
    self.minBarHeight = minBarHeight
    self.horizontalAlignment = horizontalAlignment
    self.verticalAlignment = verticalAlignment
    self.shortSamplesMode = shortSamplesMode
    self.motion = motion
    self.onSeek = onSeek
  }

  public init(
    waveform: Data,
    progress: Double,
    foreground: Color,
    background: Color,
    targetBarCount: Int = 48,
    barWidth: CGFloat = 2,
    barSpacing: CGFloat = 2,
    minBarHeight: CGFloat = 3,
    horizontalAlignment: HorizontalBarsAlignment = .leading,
    verticalAlignment: VerticalBarsAlignment = .center,
    shortSamplesMode: ShortSamplesMode = .stretch,
    motion: Motion = .fixed,
    onSeek: (@MainActor @Sendable (Double) -> Void)? = nil
  ) {
    self.init(
      samples: Array(waveform),
      progress: progress,
      foreground: foreground,
      background: background,
      targetBarCount: targetBarCount,
      barWidth: barWidth,
      barSpacing: barSpacing,
      minBarHeight: minBarHeight,
      horizontalAlignment: horizontalAlignment,
      verticalAlignment: verticalAlignment,
      shortSamplesMode: shortSamplesMode,
      motion: motion,
      onSeek: onSeek
    )
  }

  public var body: some View {
    GeometryReader { geometry in
      let barCount = Self.barCount(
        for: geometry.size.width,
        targetCount: targetBarCount,
        barWidth: barWidth,
        barSpacing: barSpacing
      )
      let targetCount = switch motion {
      case .fixed:
        barCount
      case .recordingReel:
        max(samples.count, barCount)
      }
      let bars = Self.normalizedBars(
        from: samples,
        targetCount: targetCount,
        shortSamplesMode: shortSamplesMode,
        normalizationMode: Self.normalizationMode(for: motion)
      )
      let contentWidth = Self.contentWidth(
        barCount: bars.count,
        barWidth: barWidth,
        barSpacing: barSpacing
      )
      let contentOffset = Self.contentOffset(
        containerWidth: geometry.size.width,
        contentWidth: contentWidth,
        alignment: horizontalAlignment
      )
      let progressIndex = Int((Double(bars.count) * min(max(progress, 0), 1)).rounded(.down))

      switch motion {
      case .fixed:
        AudioWaveformBars(
          bars: bars,
          filledCount: progressIndex,
          foreground: foreground,
          background: background,
          barWidth: barWidth,
          barSpacing: barSpacing,
          minBarHeight: minBarHeight,
          verticalAlignment: verticalAlignment
        )
        .frame(width: contentWidth, height: geometry.size.height, alignment: verticalAlignment.frameAlignment)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: horizontalAlignment.frameAlignment)
        .modifier(WaveformSeekModifier(
          contentOffset: contentOffset,
          contentWidth: contentWidth,
          onSeek: onSeek
        ))

      case .recordingReel:
        AudioWaveformReel(
          bars: bars,
          foreground: foreground,
          barWidth: barWidth,
          barSpacing: barSpacing,
          minBarHeight: minBarHeight,
          verticalAlignment: verticalAlignment
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
  }

  private static func barCount(
    for width: CGFloat,
    targetCount: Int,
    barWidth: CGFloat,
    barSpacing: CGFloat
  ) -> Int {
    guard width > 0 else { return max(targetCount, 1) }
    let availableCount = Int((width + barSpacing) / max(barWidth + barSpacing, 1))
    return max(1, min(max(targetCount, 1), max(availableCount, 1)))
  }

  private static func normalizedBars(
    from samples: [UInt8],
    targetCount: Int,
    shortSamplesMode: ShortSamplesMode,
    normalizationMode: NormalizationMode
  ) -> [CGFloat] {
    let count = max(targetCount, 1)
    guard !samples.isEmpty else {
      return placeholderBars(count: count)
    }

    let reduced = reduce(samples: samples, targetCount: count, shortSamplesMode: shortSamplesMode)
    switch normalizationMode {
      case .balanced:
        break
      case .recording:
        return reduced.map(normalizedRecordingBar)
    }

    let minSample = CGFloat(reduced.min() ?? 0)
    let maxSample = CGFloat(reduced.max() ?? 0)
    let spread = max(maxSample - minSample, 1)

    return reduced.map { sample in
      let value = CGFloat(sample)
      let absolute = value / 255
      let relative = (value - minSample) / spread
      let mixed = min(max(max(absolute, relative), 0), 1)
      return normalizedBar(from: mixed)
    }
  }

  private static func reduce(
    samples: [UInt8],
    targetCount: Int,
    shortSamplesMode: ShortSamplesMode
  ) -> [UInt8] {
    guard !samples.isEmpty else { return [] }
    guard samples.count != targetCount else { return samples }

    if samples.count < targetCount, shortSamplesMode == .padLeadingQuiet {
      return Array(repeating: 0, count: targetCount - samples.count) + samples
    }

    let bucketSize = Double(samples.count) / Double(targetCount)
    return (0 ..< targetCount).map { index in
      let start = Int(Double(index) * bucketSize)
      let end = min(samples.count, max(start + 1, Int(Double(index + 1) * bucketSize)))
      return samples[start ..< end].max() ?? 0
    }
  }

  private static func placeholderBars(count: Int) -> [CGFloat] {
    Array(repeating: 0.12, count: count)
  }

  private static func normalizedRecordingBar(from sample: UInt8) -> CGFloat {
    let value = CGFloat(sample) / 255
    return normalizedBar(from: min(value * 1.55, 1))
  }

  private static func normalizedBar(from value: CGFloat) -> CGFloat {
    let curved = CGFloat(pow(Double(min(max(value, 0), 1)), 0.72))
    return min(1, max(0.12, 0.12 + curved * 0.88))
  }

  private static func contentWidth(barCount: Int, barWidth: CGFloat, barSpacing: CGFloat) -> CGFloat {
    guard barCount > 0 else { return 0 }
    return CGFloat(barCount) * barWidth + CGFloat(max(barCount - 1, 0)) * barSpacing
  }

  private static func contentOffset(
    containerWidth: CGFloat,
    contentWidth: CGFloat,
    alignment: HorizontalBarsAlignment
  ) -> CGFloat {
    switch alignment {
      case .leading:
        0
      case .center:
        max((containerWidth - contentWidth) / 2, 0)
    }
  }

  private static func normalizationMode(for motion: Motion) -> NormalizationMode {
    switch motion {
      case .fixed:
        .balanced
      case .recordingReel:
        .recording
    }
  }

  private enum NormalizationMode {
    case balanced
    case recording
  }
}

@MainActor
private struct AudioWaveformBars: View {
  let bars: [CGFloat]
  let filledCount: Int
  let foreground: Color
  let background: Color
  let barWidth: CGFloat
  let barSpacing: CGFloat
  let minBarHeight: CGFloat
  let verticalAlignment: AudioWaveformView.VerticalBarsAlignment

  var body: some View {
    Canvas { context, size in
      drawBars(
        bars,
        size: size,
        context: &context
      )
    }
  }

  private func drawBars(
    _ bars: [CGFloat],
    size: CGSize,
    context: inout GraphicsContext
  ) {
    guard !bars.isEmpty, size.width > 0, size.height > 0 else { return }

    let contentWidth = CGFloat(bars.count) * barWidth + CGFloat(max(bars.count - 1, 0)) * barSpacing
    let startX = max((size.width - contentWidth) / 2, 0)

    for index in bars.indices {
      let height = max(minBarHeight, size.height * bars[index])
      let x = startX + CGFloat(index) * (barWidth + barSpacing)
      let y = yPosition(for: height, containerHeight: size.height)
      let rect = CGRect(x: x, y: y, width: barWidth, height: height)
      let path = SwiftUI.Path(roundedRect: rect, cornerRadius: barWidth / 2)
      context.fill(path, with: .color(index < filledCount ? foreground : background))
    }
  }

  private func yPosition(for height: CGFloat, containerHeight: CGFloat) -> CGFloat {
    switch verticalAlignment {
    case .center:
      (containerHeight - height) / 2
    case .bottom:
      containerHeight - height
    }
  }
}

@MainActor
private struct AudioWaveformReel: View {
  let bars: [CGFloat]
  let foreground: Color
  let barWidth: CGFloat
  let barSpacing: CGFloat
  let minBarHeight: CGFloat
  let verticalAlignment: AudioWaveformView.VerticalBarsAlignment

  @State private var xOffset: CGFloat = 0

  var body: some View {
    Canvas { context, size in
      drawBars(size: size, context: &context)
    }
    .mask {
      AudioWaveformEdgeFade(fadeWidth: Self.fadeWidth)
    }
    .onChange(of: bars) { oldValue, newValue in
      let shift = Self.shiftCount(from: oldValue, to: newValue)
      guard shift > 0 else { return }
      advanceReel(by: shift)
    }
  }

  private func drawBars(size: CGSize, context: inout GraphicsContext) {
    guard !bars.isEmpty, size.width > 0, size.height > 0 else { return }

    let contentWidth = CGFloat(bars.count) * barWidth + CGFloat(max(bars.count - 1, 0)) * barSpacing
    let startX = size.width - contentWidth + xOffset

    for index in bars.indices {
      let height = max(minBarHeight, size.height * bars[index])
      let x = startX + CGFloat(index) * (barWidth + barSpacing)
      let y = yPosition(for: height, containerHeight: size.height)
      let rect = CGRect(x: x, y: y, width: barWidth, height: height)
      let path = SwiftUI.Path(roundedRect: rect, cornerRadius: barWidth / 2)
      context.fill(path, with: .color(foreground))
    }
  }

  private func yPosition(for height: CGFloat, containerHeight: CGFloat) -> CGFloat {
    switch verticalAlignment {
    case .center:
      (containerHeight - height) / 2
    case .bottom:
      containerHeight - height
    }
  }

  private func advanceReel(by shift: Int) {
    xOffset = CGFloat(shift) * (barWidth + barSpacing)
    withAnimation(Self.reelAnimation) {
      xOffset = 0
    }
  }

  private static func shiftCount(from oldValue: [CGFloat], to newValue: [CGFloat]) -> Int {
    guard oldValue != newValue else { return 0 }
    guard !oldValue.isEmpty, !newValue.isEmpty else { return 1 }

    let maxOverlap = min(oldValue.count, newValue.count)
    for overlap in stride(from: maxOverlap, through: 1, by: -1) {
      let oldStart = oldValue.count - overlap
      if Array(oldValue[oldStart ..< oldValue.count]) == Array(newValue[0 ..< overlap]) {
        return max(1, newValue.count - overlap)
      }
    }

    return 1
  }

  private static let fadeWidth: CGFloat = 14
  private static let reelAnimation: Animation = .linear(duration: 1.0 / 30.0)
}

private struct AudioWaveformEdgeFade: View {
  let fadeWidth: CGFloat

  var body: some View {
    GeometryReader { geometry in
      let width = min(fadeWidth, geometry.size.width / 2)

      HStack(spacing: 0) {
        LinearGradient(
          colors: [.clear, .black],
          startPoint: .leading,
          endPoint: .trailing
        )
        .frame(width: width)

        Rectangle()
          .fill(.black)

        LinearGradient(
          colors: [.black, .clear],
          startPoint: .leading,
          endPoint: .trailing
        )
        .frame(width: width)
      }
    }
  }
}

private struct WaveformSeekModifier: ViewModifier {
  let contentOffset: CGFloat
  let contentWidth: CGFloat
  let onSeek: (@MainActor @Sendable (Double) -> Void)?

  func body(content: Content) -> some View {
    if let onSeek {
      content
        .contentShape(Rectangle())
        .gesture(
          DragGesture(minimumDistance: 0)
            .onChanged { value in
              guard contentWidth > 0 else { return }
              let x = value.location.x - contentOffset
              onSeek(min(max(x / contentWidth, 0), 1))
            }
        )
    } else {
      content
    }
  }
}

private extension AudioWaveformView.HorizontalBarsAlignment {
  var frameAlignment: Alignment {
    switch self {
      case .leading:
        .leading
      case .center:
        .center
    }
  }
}

private extension AudioWaveformView.VerticalBarsAlignment {
  var stackAlignment: VerticalAlignment {
    switch self {
      case .center:
        .center
      case .bottom:
        .bottom
    }
  }

  var frameAlignment: Alignment {
    switch self {
      case .center:
        .center
      case .bottom:
        .bottom
    }
  }
}
