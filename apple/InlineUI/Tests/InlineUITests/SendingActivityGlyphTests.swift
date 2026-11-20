import CoreGraphics
import Foundation
import ImageIO
@testable import InlineUI
import SwiftUI
import Testing

private func render(_ kind: SendingActivityGlyph.Kind, time: TimeInterval, scale: CGFloat = 4) -> [UInt8] {
  let size = SendingActivityGlyph.designSize
  let width = Int(size.width * scale), height = Int(size.height * scale)
  var pixels = [UInt8](repeating: 0, count: width * height * 4)
  pixels.withUnsafeMutableBytes { buffer in
    let context = CGContext(
      data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.translateBy(x: 0, y: CGFloat(height))
    context.scaleBy(x: 1, y: -1)
    SendingActivityGlyph.draw(
      kind, in: context, rect: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)),
      time: time, color: CGColor(srgbRed: 0.2, green: 0.47, blue: 0.96, alpha: 1)
    )
  }
  return pixels
}

private func difference(_ a: [UInt8], _ b: [UInt8]) -> Int {
  zip(a, b).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }
}

@Suite("Sending activity glyphs")
struct SendingActivityGlyphTests {
  @Test("each loop ends exactly where it starts, so there's no visible jump", arguments: SendingActivityGlyph.Kind.allCases)
  func loopIsSeamless(kind: SendingActivityGlyph.Kind) {
    let cycle = SendingActivityGlyph.cycleDuration(for: kind)
    let start = render(kind, time: 1000 * cycle)
    let end = render(kind, time: 1000 * cycle - 0.0001)
    // Allow a few anti-aliasing steps from the 0.1ms difference.
    #expect(difference(start, end) < 4000)
  }

  @Test("motion never pops: every 60Hz step ramps in and out", arguments: SendingActivityGlyph.Kind.allCases)
  func motionHasNoPops(kind: SendingActivityGlyph.Kind) {
    let frames = Int(SendingActivityGlyph.cycleDuration(for: kind) * 60)
    var deltas: [Double] = []
    var previous = render(kind, time: 0)
    for frame in 1 ... frames {
      let current = render(kind, time: Double(frame) / 60)
      deltas.append(Double(difference(previous, current)))
      previous = current
    }
    // A pop is one step far bigger than both of its neighbours; fast motion ramps.
    for index in deltas.indices {
      let neighbours = max(deltas[(index - 1 + frames) % frames], deltas[(index + 1) % frames], 2000)
      #expect(deltas[index] / neighbours < 2.5, "\(kind) pops at \(Double(index) / Double(frames))")
    }
  }

  @Test("every kind draws something at every point in its loop", arguments: SendingActivityGlyph.Kind.allCases)
  func alwaysVisible(kind: SendingActivityGlyph.Kind) {
    let cycle = SendingActivityGlyph.cycleDuration(for: kind)
    for step in 0 ..< 24 {
      let frame = render(kind, time: cycle * Double(step) / 24)
      let inked = stride(from: 3, to: frame.count, by: 4).count { frame[$0] > 128 }
      #expect(inked > 120, "frame \(step) of \(kind) is almost empty")
    }
  }

  @Test("the three kinds are distinct shapes")
  func kindsDiffer() {
    let photo = render(.photo, time: SendingActivityGlyph.restingTime(for: .photo))
    let video = render(.video, time: SendingActivityGlyph.restingTime(for: .video))
    let file = render(.file, time: SendingActivityGlyph.restingTime(for: .file))
    #expect(difference(photo, video) > 100_000)
    #expect(difference(photo, file) > 100_000)
    #expect(difference(video, file) > 100_000)
  }

  @Test("upload actions map to their glyph")
  func mapping() {
    #expect(SendingActivityGlyph.Kind(.uploadingPhoto) == .photo)
    #expect(SendingActivityGlyph.Kind(.uploadingVideo) == .video)
    #expect(SendingActivityGlyph.Kind(.uploadingDocument) == .file)
    #expect(SendingActivityGlyph.Kind(.typing) == nil)
    #expect(SendingActivityGlyph.Kind(.recordingVoice) == nil)
  }

  /// Writes real SwiftUI renders of the status lines when INLINE_GLYPH_SNAPSHOT_DIR is set.
  @MainActor
  @Test("SwiftUI status lines render")
  func swiftUIStatusLines() throws {
    let directory = ProcessInfo.processInfo.environment["INLINE_GLYPH_SNAPSHOT_DIR"]
    for scheme in [ColorScheme.light, .dark] {
      let view = VStack(alignment: .leading, spacing: 10) {
        ForEach(SendingActivityGlyph.Kind.allCases, id: \.self) { kind in
          HStack(spacing: 4) {
            SendingActivityIndicator(kind: kind, color: .accentColor)
            Text("sending \(kind == .file ? "file" : kind.rawValue)")
              .font(.system(size: 12))
              .foregroundStyle(Color.accentColor)
          }
        }
      }
      .padding(12)
      .background(scheme == .dark ? Color(white: 0.11) : .white)
      .environment(\.colorScheme, scheme)

      let renderer = ImageRenderer(content: view)
      renderer.scale = 3
      let image = try #require(renderer.cgImage)
      #expect(image.width > 100)
      if let directory {
        let url = URL(fileURLWithPath: directory).appendingPathComponent("swiftui-\(scheme == .dark ? "dark" : "light").png")
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
      }
    }
  }
}
