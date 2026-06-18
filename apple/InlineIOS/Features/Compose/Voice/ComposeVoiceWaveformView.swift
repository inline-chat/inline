import SwiftUI

@MainActor
struct ComposeVoiceWaveformView: View {
  let samples: [UInt8]
  let progress: Double
  let foreground: Color
  let background: Color
  let onSeek: (@MainActor @Sendable (Double) -> Void)?

  init(
    samples: [UInt8],
    progress: Double,
    foreground: Color = .accentColor,
    background: Color = Color(uiColor: .tertiaryLabel).opacity(0.35),
    onSeek: (@MainActor @Sendable (Double) -> Void)? = nil
  ) {
    self.samples = samples
    self.progress = progress
    self.foreground = foreground
    self.background = background
    self.onSeek = onSeek
  }

  var body: some View {
    GeometryReader { geometry in
      let barCount = Self.barCount(for: geometry.size.width)
      let bars = Self.bars(from: samples, count: barCount)
      let clampedProgress = min(max(progress, 0), 1)
      let filledCount = Int((Double(bars.count) * clampedProgress).rounded(.down))

      Canvas { context, size in
        drawBars(
          bars,
          filledCount: filledCount,
          size: size,
          context: &context
        )
      }
      .contentShape(Rectangle())
      .gesture(seekGesture(width: geometry.size.width))
    }
  }

  private func drawBars(
    _ bars: [CGFloat],
    filledCount: Int,
    size: CGSize,
    context: inout GraphicsContext
  ) {
    guard !bars.isEmpty, size.width > 0, size.height > 0 else { return }

    let spacing = Self.barSpacing
    let width = Self.barWidth
    let contentWidth = CGFloat(bars.count) * width + CGFloat(max(bars.count - 1, 0)) * spacing
    let startX = max((size.width - contentWidth) / 2, 0)

    for index in bars.indices {
      let height = max(Self.minBarHeight, size.height * bars[index])
      let x = startX + CGFloat(index) * (width + spacing)
      let y = (size.height - height) / 2
      let rect = CGRect(x: x, y: y, width: width, height: height)
      let path = SwiftUI.Path(roundedRect: rect, cornerRadius: width / 2)
      context.fill(path, with: .color(index < filledCount ? foreground : background))
    }
  }

  private func seekGesture(width: CGFloat) -> some Gesture {
    DragGesture(minimumDistance: 0)
      .onChanged { value in
        guard let onSeek, width > 0 else { return }
        onSeek(min(max(value.location.x / width, 0), 1))
      }
  }

  private static func barCount(for width: CGFloat) -> Int {
    guard width > 0 else { return 32 }
    let count = Int((width + barSpacing) / (barWidth + barSpacing))
    return max(16, min(count, 72))
  }

  private static func bars(from samples: [UInt8], count: Int) -> [CGFloat] {
    let count = max(count, 1)
    guard !samples.isEmpty else {
      return placeholderBars(count: count)
    }

    let reduced = reduce(samples: samples, count: count)
    let maxSample = max(CGFloat(reduced.max() ?? 0), 1)

    return reduced.map { sample in
      let absolute = CGFloat(sample) / 255
      let relative = CGFloat(sample) / maxSample
      let mixed = max(absolute, relative)
      let curved = CGFloat(pow(Double(min(max(mixed, 0), 1)), 0.72))
      return min(max(0.12 + curved * 0.88, 0.12), 1)
    }
  }

  private static func reduce(samples: [UInt8], count: Int) -> [UInt8] {
    guard samples.count != count else { return samples }

    if samples.count < count {
      let scale = Double(max(samples.count - 1, 0)) / Double(max(count - 1, 1))
      return (0 ..< count).map { index in
        samples[Int((Double(index) * scale).rounded())]
      }
    }

    let bucketSize = Double(samples.count) / Double(count)
    return (0 ..< count).map { index in
      let start = Int(Double(index) * bucketSize)
      let end = min(samples.count, max(start + 1, Int(Double(index + 1) * bucketSize)))
      return samples[start ..< end].max() ?? 0
    }
  }

  private static func placeholderBars(count: Int) -> [CGFloat] {
    let pattern: [CGFloat] = [0.18, 0.26, 0.15, 0.32, 0.2, 0.28, 0.16, 0.24]
    return (0 ..< count).map { pattern[$0 % pattern.count] }
  }

  private static let barWidth: CGFloat = 2
  private static let barSpacing: CGFloat = 2
  private static let minBarHeight: CGFloat = 3
}
