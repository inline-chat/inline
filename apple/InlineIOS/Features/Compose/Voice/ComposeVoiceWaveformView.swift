import SwiftUI

@MainActor
struct ComposeVoiceWaveformView: View {
  enum Motion {
    case fixed
    case recordingReel
  }

  let samples: [UInt8]
  let progress: Double
  let foreground: Color
  let background: Color
  let motion: Motion
  let onSeek: (@MainActor @Sendable (Double) -> Void)?

  @State private var lastSeekTime: TimeInterval = 0
  @State private var lastSeekProgress: Double = 0

  init(
    samples: [UInt8],
    progress: Double,
    foreground: Color = Color(uiColor: .secondaryLabel),
    background: Color = Color(uiColor: .tertiaryLabel).opacity(0.35),
    motion: Motion = .fixed,
    onSeek: (@MainActor @Sendable (Double) -> Void)? = nil
  ) {
    self.samples = samples
    self.progress = progress
    self.foreground = foreground
    self.background = background
    self.motion = motion
    self.onSeek = onSeek
  }

  var body: some View {
    GeometryReader { geometry in
      let barCount = Self.barCount(for: geometry.size.width, motion: motion)
      let targetCount = switch motion {
      case .fixed:
        barCount
      case .recordingReel:
        max(samples.count, barCount)
      }
      let bars = Self.bars(from: samples, count: targetCount, motion: motion)
      let clampedProgress = min(max(progress, 0), 1)
      let filledCount = Int((Double(bars.count) * clampedProgress).rounded(.down))

      switch motion {
      case .fixed:
        ComposeVoiceWaveformBars(
          bars: bars,
          filledCount: filledCount,
          foreground: foreground,
          background: background
        )
        .contentShape(Rectangle())
        .gesture(seekGesture(width: geometry.size.width), including: onSeek == nil ? .none : .all)

      case .recordingReel:
        ComposeVoiceWaveformReel(
          bars: bars,
          foreground: foreground
        )
      }
    }
  }

  private func seekGesture(width: CGFloat) -> some Gesture {
    DragGesture(minimumDistance: 0)
      .onChanged { value in
        commitSeek(locationX: value.location.x, width: width, force: false)
      }
      .onEnded { value in
        commitSeek(locationX: value.location.x, width: width, force: true)
      }
  }

  private func commitSeek(locationX: CGFloat, width: CGFloat, force: Bool) {
    guard let onSeek, width > 0 else { return }

    let progress = Double(min(max(locationX / width, 0), 1))
    let now = ProcessInfo.processInfo.systemUptime
    guard force ||
      now - lastSeekTime >= Self.seekCommitInterval ||
      abs(progress - lastSeekProgress) >= Self.seekProgressThreshold
    else {
      return
    }

    lastSeekTime = now
    lastSeekProgress = progress
    onSeek(progress)
  }

  private static func barCount(for width: CGFloat, motion: Motion) -> Int {
    guard width > 0 else { return 32 }
    let stride = VoiceWaveformMetrics.barWidth + VoiceWaveformMetrics.barSpacing
    let count = Int((width + VoiceWaveformMetrics.barSpacing) / stride)

    switch motion {
    case .fixed:
      return max(16, min(count, 72))
    case .recordingReel:
      return max(16, count + 2)
    }
  }

  private static func bars(from samples: [UInt8], count: Int, motion: Motion) -> [CGFloat] {
    let count = max(count, 1)
    guard !samples.isEmpty else {
      return placeholderBars(count: count)
    }

    let reduced = reduce(
      samples: samples,
      count: count,
      padLeadingQuiet: motion == .recordingReel
    )
    if motion == .recordingReel {
      return reduced.map(normalizedAbsoluteBar)
    }

    let maxSample = max(CGFloat(reduced.max() ?? 0), 1)

    return reduced.map { sample in
      let absolute = CGFloat(sample) / 255
      let relative = CGFloat(sample) / maxSample
      let mixed = max(absolute, relative)
      return normalizedBar(from: mixed)
    }
  }

  private static func reduce(samples: [UInt8], count: Int, padLeadingQuiet: Bool) -> [UInt8] {
    guard samples.count != count else { return samples }

    if samples.count < count, padLeadingQuiet {
      return Array(repeating: 0, count: count - samples.count) + samples
    }

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
    Array(repeating: 0.12, count: count)
  }

  private static func normalizedAbsoluteBar(from sample: UInt8) -> CGFloat {
    normalizedBar(from: CGFloat(sample) / 255)
  }

  private static func normalizedBar(from value: CGFloat) -> CGFloat {
    let curved = CGFloat(pow(Double(min(max(value, 0), 1)), 0.72))
    return min(max(0.12 + curved * 0.88, 0.12), 1)
  }

  private static let seekCommitInterval: TimeInterval = 1.0 / 30.0
  private static let seekProgressThreshold: Double = 0.015
}

@MainActor
private struct ComposeVoiceWaveformBars: View {
  let bars: [CGFloat]
  let filledCount: Int
  let foreground: Color
  let background: Color

  var body: some View {
    Canvas { context, size in
      drawBars(
        bars,
        filledCount: filledCount,
        size: size,
        context: &context
      )
    }
  }

  private func drawBars(
    _ bars: [CGFloat],
    filledCount: Int,
    size: CGSize,
    context: inout GraphicsContext
  ) {
    guard !bars.isEmpty, size.width > 0, size.height > 0 else { return }

    let spacing = VoiceWaveformMetrics.barSpacing
    let width = VoiceWaveformMetrics.barWidth
    let contentWidth = CGFloat(bars.count) * width + CGFloat(max(bars.count - 1, 0)) * spacing
    let startX = max((size.width - contentWidth) / 2, 0)

    for index in bars.indices {
      let height = max(VoiceWaveformMetrics.minBarHeight, size.height * bars[index])
      let x = startX + CGFloat(index) * (width + spacing)
      let y = (size.height - height) / 2
      let rect = CGRect(x: x, y: y, width: width, height: height)
      let path = SwiftUI.Path(roundedRect: rect, cornerRadius: width / 2)
      context.fill(path, with: .color(index < filledCount ? foreground : background))
    }
  }
}

@MainActor
private struct ComposeVoiceWaveformReel: View {
  let bars: [CGFloat]
  let foreground: Color

  @State private var xOffset: CGFloat = 0

  var body: some View {
    Canvas { context, size in
      drawBars(size: size, context: &context)
    }
    .mask {
      VoiceWaveformEdgeFade(fadeWidth: Self.fadeWidth)
    }
    .onChange(of: bars) { oldValue, newValue in
      let shift = Self.shiftCount(from: oldValue, to: newValue)
      guard shift > 0 else { return }
      advanceReel(by: shift)
    }
  }

  private func drawBars(size: CGSize, context: inout GraphicsContext) {
    guard !bars.isEmpty, size.width > 0, size.height > 0 else { return }

    let spacing = VoiceWaveformMetrics.barSpacing
    let width = VoiceWaveformMetrics.barWidth
    let contentWidth = CGFloat(bars.count) * width + CGFloat(max(bars.count - 1, 0)) * spacing
    let startX = size.width - contentWidth + xOffset

    for index in bars.indices {
      let height = max(VoiceWaveformMetrics.minBarHeight, size.height * bars[index])
      let x = startX + CGFloat(index) * (width + spacing)
      let y = (size.height - height) / 2
      let rect = CGRect(x: x, y: y, width: width, height: height)
      let path = SwiftUI.Path(roundedRect: rect, cornerRadius: width / 2)
      context.fill(path, with: .color(foreground))
    }
  }

  private func advanceReel(by shift: Int) {
    xOffset = CGFloat(shift) * (VoiceWaveformMetrics.barWidth + VoiceWaveformMetrics.barSpacing)
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
  private static let reelAnimation: Animation = .linear(duration: 1.0 / 25.0)
}

private struct VoiceWaveformEdgeFade: View {
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

private enum VoiceWaveformMetrics {
  static let barWidth: CGFloat = 2
  static let barSpacing: CGFloat = 2
  static let minBarHeight: CGFloat = 3
}
