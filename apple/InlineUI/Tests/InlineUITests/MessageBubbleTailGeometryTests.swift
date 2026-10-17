import CoreGraphics
import Testing

@testable import InlineUI

@Suite("Message bubble tail geometry")
struct MessageBubbleTailGeometryTests {
  private static let sizes: [CGSize] = [
    CGSize(width: 40, height: 20),
    CGSize(width: 72, height: 24),
    CGSize(width: 72, height: 28),
    CGSize(width: 90, height: 36),
    CGSize(width: 160, height: 46),
    CGSize(width: 260, height: 180),
  ]

  @Test("radius matches Core Animation clamping")
  func effectiveRadius() {
    #expect(MessageBubbleTailGeometry.effectiveRadius(cornerRadius: 14, size: CGSize(width: 100, height: 60)) == 14)
    #expect(MessageBubbleTailGeometry.effectiveRadius(cornerRadius: 14, size: CGSize(width: 100, height: 24)) == 12)
    #expect(MessageBubbleTailGeometry.effectiveRadius(cornerRadius: 18, size: CGSize(width: 20, height: 60)) == 10)
  }

  @Test("tail starts on the side edge and its notch lands on the corner arc", arguments: [14.0, 18.0])
  func attachesToBody(cornerRadius: CGFloat) {
    for size in Self.sizes {
      let radius = MessageBubbleTailGeometry.effectiveRadius(cornerRadius: cornerRadius, size: size)
      let corner = CGPoint(x: size.width, y: size.height)
      let points = MessageBubbleTailGeometry.tailPath(corner: corner, radius: radius, side: .trailing).endPoints

      #expect(points.first == CGPoint(x: corner.x, y: corner.y - radius))
      #expect(abs(points[1].x - corner.x) < 0.0001)

      // The notch quad ends on the arc, and the outline then closes through the arc center.
      let center = CGPoint(x: corner.x - radius, y: corner.y - radius)
      let notchEnd = points[points.count - 3]
      #expect(abs(hypot(notchEnd.x - center.x, notchEnd.y - center.y) - radius) < 0.0001)
      #expect(points[points.count - 2] == center)
    }
  }

  @Test("tail stays inside the corner box and the reserved width", arguments: [14.0, 18.0])
  func staysInCornerBox(cornerRadius: CGFloat) {
    for size in Self.sizes {
      let radius = MessageBubbleTailGeometry.effectiveRadius(cornerRadius: cornerRadius, size: size)
      let corner = CGPoint(x: size.width, y: size.height)
      let box = MessageBubbleTailGeometry.tailPath(corner: corner, radius: radius, side: .trailing).boundingBoxOfPath
      let exposed = MessageBubbleTailGeometry.exposedWidth(radius: radius)

      #expect(box.minX >= corner.x - radius - 0.0001)
      #expect(box.minY >= corner.y - radius - 0.0001)
      #expect(box.maxY <= corner.y + 0.0001)
      #expect(box.maxX <= corner.x + exposed + 0.0001)
      #expect(box.maxX > corner.x + exposed * 0.9)
    }
  }

  @Test("leading tail mirrors trailing", arguments: [14.0, 18.0])
  func leadingMirrorsTrailing(cornerRadius: CGFloat) throws {
    for size in Self.sizes {
      let canvas = CGSize(width: size.width + 40, height: size.height + 4)
      let trailingBody = CGRect(x: 4, y: 0, width: size.width, height: size.height)
      let leadingBody = CGRect(x: canvas.width - 4 - size.width, y: 0, width: size.width, height: size.height)

      let trailing = try rasterize(
        MessageBubbleTailGeometry.bubblePath(body: trailingBody, cornerRadius: cornerRadius, side: .trailing),
        size: canvas
      )
      let leading = try rasterize(
        MessageBubbleTailGeometry.bubblePath(body: leadingBody, cornerRadius: cornerRadius, side: .leading),
        size: canvas
      )

      let width = Int(canvas.width * 2)
      let height = trailing.count / width
      var difference = 0
      for y in 0 ..< height {
        for x in 0 ..< width {
          difference += abs(Int(trailing[y * width + x]) - Int(leading[y * width + (width - 1 - x)]))
        }
      }
      #expect(Double(difference) / Double(trailing.count) < 0.5, "size \(size)")
    }
  }

  @Test("body and tail union under the non-zero rule", arguments: [14.0, 18.0])
  func unionsUnderNonZero(cornerRadius: CGFloat) throws {
    for side in [MessageBubbleTailGeometry.Side.leading, .trailing] {
      for size in Self.sizes {
        let canvas = CGSize(width: size.width + 40, height: size.height + 4)
        let body = CGRect(x: 20, y: 0, width: size.width, height: size.height)
        let radius = MessageBubbleTailGeometry.effectiveRadius(cornerRadius: cornerRadius, size: size)
        let corner = CGPoint(x: side == .trailing ? body.maxX : body.minX, y: body.maxY)

        let combined = try rasterize(
          MessageBubbleTailGeometry.bubblePath(body: body, cornerRadius: cornerRadius, side: side),
          size: canvas
        )
        let separate = try rasterize(
          [
            MessageBubbleTailGeometry.bubblePath(body: body, cornerRadius: cornerRadius, side: nil),
            MessageBubbleTailGeometry.tailPath(corner: corner, radius: radius, side: side),
          ],
          size: canvas
        )

        // Opposite winding would cancel the overlap into a hole. Shared edges only differ
        // by antialiasing, since separate fills composite their partial coverage twice.
        let holes = zip(combined, separate).filter { $0 < 128 && $1 > 250 }.count
        let mean = Double(zip(combined, separate).map { abs(Int($0) - Int($1)) }.reduce(0, +)) / Double(combined.count)
        #expect(holes == 0, "side \(side) size \(size)")
        #expect(mean < 0.5, "side \(side) size \(size)")
      }
    }
  }

  /// Renders paths at 2x into an 8-bit alpha buffer, each filled on its own (non-zero).
  private func rasterize(_ paths: [CGPath], size: CGSize) throws -> [UInt8] {
    let width = Int(size.width * 2)
    let height = Int(size.height * 2)
    var buffer = [UInt8](repeating: 0, count: width * height)
    try buffer.withUnsafeMutableBytes { bytes in
      let context = try #require(CGContext(
        data: bytes.baseAddress,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width,
        space: CGColorSpaceCreateDeviceGray(),
        bitmapInfo: CGImageAlphaInfo.none.rawValue
      ))
      context.scaleBy(x: 2, y: 2)
      context.setFillColor(gray: 1, alpha: 1)
      for path in paths {
        context.addPath(path)
        context.fillPath()
      }
    }
    return buffer
  }

  private func rasterize(_ path: CGPath, size: CGSize) throws -> [UInt8] {
    try rasterize([path], size: size)
  }
}

private extension CGPath {
  var endPoints: [CGPoint] {
    var points: [CGPoint] = []
    applyWithBlock { element in
      let element = element.pointee
      switch element.type {
      case .moveToPoint, .addLineToPoint:
        points.append(element.points[0])
      case .addQuadCurveToPoint:
        points.append(element.points[1])
      case .addCurveToPoint:
        points.append(element.points[2])
      case .closeSubpath:
        break
      @unknown default:
        break
      }
    }
    return points
  }
}
