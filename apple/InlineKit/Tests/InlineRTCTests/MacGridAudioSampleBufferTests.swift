#if os(macOS)
import Testing

@testable import InlineRTC

@Suite("macOS remote audio sample buffer")
struct MacGridAudioSampleBufferTests {
  @Test("reads PCM in order and renders silence on underrun")
  func fifoAndUnderrun() {
    let buffer = MacGridAudioSampleBuffer(capacity: 8)

    #expect(write([1, 2, 3], to: buffer) == 3)
    #expect(read(5, from: buffer) == [1, 2, 3, 0, 0])
  }

  @Test("wraps without reordering samples")
  func wraps() {
    let buffer = MacGridAudioSampleBuffer(capacity: 6)

    #expect(write([1, 2, 3, 4], to: buffer) == 4)
    #expect(read(3, from: buffer) == [1, 2, 3])
    #expect(write([5, 6, 7, 8], to: buffer) == 4)
    #expect(read(5, from: buffer) == [4, 5, 6, 7, 8])
  }

  @Test("drops a whole packet instead of growing playout latency")
  func boundedOverflow() {
    let buffer = MacGridAudioSampleBuffer(capacity: 5)

    #expect(write([1, 2, 3, 4], to: buffer) == 4)
    #expect(write([5, 6], to: buffer) == 0)
    #expect(read(5, from: buffer) == [1, 2, 3, 4, 0])
  }

  @Test("playout waits for enough PCM to cover mismatched callback sizes")
  func playoutPrebuffers() {
    let playout = MacGridAudioPlayoutBuffer(capacity: 16, startupThreshold: 6)

    #expect(write([1, 2, 3, 4], to: playout) == 4)
    #expect(read(4, from: playout) == (.buffering, [0, 0, 0, 0]))
    #expect(write([5, 6, 7, 8], to: playout) == 4)
    #expect(read(4, from: playout) == (.playing, [1, 2, 3, 4]))
  }

  @Test("an underrun returns to bounded prebuffering")
  func playoutRebuffersAfterUnderrun() {
    let playout = MacGridAudioPlayoutBuffer(capacity: 16, startupThreshold: 4)

    #expect(write([1, 2, 3, 4], to: playout) == 4)
    #expect(read(3, from: playout) == (.playing, [1, 2, 3]))
    #expect(read(3, from: playout) == (.underflow(samplesRead: 1), [4, 0, 0]))
    #expect(write([5, 6, 7], to: playout) == 3)
    #expect(read(3, from: playout) == (.buffering, [0, 0, 0]))
    #expect(write([8], to: playout) == 1)
    #expect(read(3, from: playout) == (.playing, [5, 6, 7]))
  }

  @Test("10 ms WebRTC packets continuously feed 512-frame Core Audio callbacks")
  func packetAndHardwareCadenceStayContinuous() {
    let playout = MacGridAudioPlayoutBuffer(capacity: 96_000, startupThreshold: 2_880)
    let packet = Array(repeating: Float(0.25), count: 960)
    var producerTime = 0.0
    var underflows = 0

    for callback in 0 ..< 500 {
      let consumerTime = Double(callback * 512) / 48_000
      while producerTime <= consumerTime {
        #expect(write(packet, to: playout) == packet.count)
        producerTime += 0.01
      }
      let (result, _) = read(1_024, from: playout)
      if case .underflow = result { underflows += 1 }
    }

    #expect(underflows == 0)
  }

  @Test("hardware health expires when realtime callbacks stop advancing")
  func callbackProgressMustRemainRecent() {
    var progress = MacGridAudioProgressMonitor(stallTimeout: 1)

    let stopped = progress.observe(isStarted: false, frameCount: 0, now: 0)
    let started = progress.observe(isStarted: true, frameCount: 512, now: 1)
    let stillRecent = progress.observe(isStarted: true, frameCount: 512, now: 1.9)
    let stalled = progress.observe(isStarted: true, frameCount: 512, now: 2.1)
    let resumed = progress.observe(isStarted: true, frameCount: 1_024, now: 2.2)

    #expect(!stopped)
    #expect(started)
    #expect(stillRecent)
    #expect(!stalled)
    #expect(resumed)

    progress.reset()
    let replaced = progress.observe(isStarted: true, frameCount: 512, now: 10)
    #expect(replaced)
  }

  private func write(_ values: [Float], to buffer: MacGridAudioSampleBuffer) -> Int {
    values.withUnsafeBufferPointer { buffer.write($0) }
  }

  private func read(_ count: Int, from buffer: MacGridAudioSampleBuffer) -> [Float] {
    var values = Array(repeating: Float(-1), count: count)
    values.withUnsafeMutableBufferPointer { _ = buffer.read(into: $0) }
    return values
  }

  private func write(_ values: [Float], to buffer: MacGridAudioPlayoutBuffer) -> Int {
    values.withUnsafeBufferPointer { buffer.write($0) }
  }

  private func read(
    _ count: Int,
    from buffer: MacGridAudioPlayoutBuffer
  ) -> (MacGridAudioPlayoutRead, [Float]) {
    var values = Array(repeating: Float(-1), count: count)
    let result = values.withUnsafeMutableBufferPointer { buffer.read(into: $0) }
    return (result, values)
  }
}
#endif
