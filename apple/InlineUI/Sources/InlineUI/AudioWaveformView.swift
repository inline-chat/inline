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
      let bars = Self.normalizedBars(from: samples, targetCount: barCount)
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

      HStack(alignment: verticalAlignment.stackAlignment, spacing: barSpacing) {
        ForEach(Array(bars.enumerated()), id: \.offset) { index, value in
          Capsule(style: .continuous)
            .fill(index < progressIndex ? foreground : background)
            .frame(
              width: barWidth,
              height: max(minBarHeight, geometry.size.height * value)
            )
        }
      }
      .frame(width: contentWidth, height: geometry.size.height, alignment: verticalAlignment.frameAlignment)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: horizontalAlignment.frameAlignment)
      .modifier(WaveformSeekModifier(
        contentOffset: contentOffset,
        contentWidth: contentWidth,
        onSeek: onSeek
      ))
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

  private static func normalizedBars(from samples: [UInt8], targetCount: Int) -> [CGFloat] {
    let count = max(targetCount, 1)
    guard !samples.isEmpty else {
      return placeholderBars(count: count)
    }

    let reduced = reduce(samples: samples, targetCount: count)
    let minSample = CGFloat(reduced.min() ?? 0)
    let maxSample = CGFloat(reduced.max() ?? 0)
    let spread = max(maxSample - minSample, 1)

    return reduced.map { sample in
      let value = CGFloat(sample)
      let absolute = value / 255
      let relative = (value - minSample) / spread
      let mixed = min(max(max(absolute, relative), 0), 1)
      let curved = CGFloat(pow(Double(mixed), 0.72))
      return min(1, max(0.12, 0.12 + curved * 0.88))
    }
  }

  private static func reduce(samples: [UInt8], targetCount: Int) -> [UInt8] {
    guard !samples.isEmpty else { return [] }
    guard samples.count != targetCount else { return samples }

    let bucketSize = Double(samples.count) / Double(targetCount)
    return (0 ..< targetCount).map { index in
      let start = Int(Double(index) * bucketSize)
      let end = min(samples.count, max(start + 1, Int(Double(index + 1) * bucketSize)))
      return samples[start ..< end].max() ?? 0
    }
  }

  private static func placeholderBars(count: Int) -> [CGFloat] {
    let pattern: [CGFloat] = [0.14, 0.22, 0.16, 0.28, 0.18, 0.24, 0.15, 0.2]
    return (0 ..< count).map { pattern[$0 % pattern.count] }
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
