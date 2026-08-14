import Foundation
import Testing

@testable import InlineUI

@Suite("AudioWaveformView")
struct AudioWaveformViewTests {
  @Test("default relative scale preserves existing waveform rendering")
  func relativeScaleKeepsExistingCurve() {
    let bars = AudioWaveformView.normalizedBars(
      from: [0, 64, 255],
      targetCount: 3,
      shortSamplesMode: .stretch,
      amplitudeScale: .relative
    )

    let expectedMiddle = 0.12 + pow(CGFloat(64) / 255, 0.72) * 0.88
    #expect(bars[0] == 0.12)
    #expect(abs(bars[1] - expectedMiddle) < 0.000_001)
    #expect(bars[2] == 1)
  }

  @Test("later peaks do not rescale historical bars")
  func laterPeaksKeepHistoricalBarsStable() {
    let initialSamples: [UInt8] = [0, 24, 72, 128]
    let initialBars = AudioWaveformView.normalizedBars(
      from: initialSamples,
      targetCount: initialSamples.count,
      shortSamplesMode: .stretch,
      amplitudeScale: .fixed
    )
    let extendedBars = AudioWaveformView.normalizedBars(
      from: initialSamples + [255],
      targetCount: initialSamples.count + 1,
      shortSamplesMode: .stretch,
      amplitudeScale: .fixed
    )

    #expect(Array(extendedBars.prefix(initialBars.count)) == initialBars)
  }

  @Test("fixed amplitude maps to the same height in every window")
  func amplitudeScaleDoesNotDependOnNeighbors() {
    let quietWindow = AudioWaveformView.normalizedBars(
      from: [0, 96, 112],
      targetCount: 3,
      shortSamplesMode: .stretch,
      amplitudeScale: .fixed
    )
    let loudWindow = AudioWaveformView.normalizedBars(
      from: [96, 224, 255],
      targetCount: 3,
      shortSamplesMode: .stretch,
      amplitudeScale: .fixed
    )

    #expect(quietWindow[1] == loudWindow[0])
    #expect(quietWindow[0] == 0.12)
    #expect(loudWindow[2] == 1)
  }

  @Test("recording overflow preserves sample identity instead of rebucketing history")
  func recordingOverflowKeepsAStableSlidingWindow() {
    let firstWindow = AudioWaveformView.normalizedBars(
      from: [8, 24, 72, 128],
      targetCount: 3,
      shortSamplesMode: .padLeadingQuiet,
      amplitudeScale: .fixed
    )
    let nextWindow = AudioWaveformView.normalizedBars(
      from: [24, 72, 128, 160],
      targetCount: 3,
      shortSamplesMode: .padLeadingQuiet,
      amplitudeScale: .fixed
    )

    #expect(Array(firstWindow.dropFirst()) == Array(nextWindow.dropLast()))
  }
}
