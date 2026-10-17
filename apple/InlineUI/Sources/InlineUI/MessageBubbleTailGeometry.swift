import CoreGraphics
import Foundation

/// Shared geometry for the chat bubble tail.
///
/// The tail is defined in units of the bubble's effective corner radius
/// (`effectiveRadius`), so its shoulder always meets the straight side where the
/// corner arc begins and its notch always lands on the corner arc, whatever the
/// bubble size, font, or line height. Coordinates are y-down.
///
/// `tailPath` includes the corner area under the body, so it is meant to be filled
/// together with a circular rounded-rect body of the same radius: either appended to
/// it (both wind clockwise, so the non-zero rule unions them) or drawn beneath it.
public enum MessageBubbleTailGeometry {
  public enum Side: Sendable {
    case leading
    case trailing
  }

  // Shape constants in units of the corner radius. x grows away from the bubble,
  // y grows down from the bottom edge.
  static let shoulderHeight: CGFloat = 0.78
  static let sideControl1Height: CGFloat = 0.3705
  static let sideControl2Height: CGFloat = 0.165
  static let tip = CGPoint(x: 0.335, y: -0.005)
  static let undersideControl1 = CGPoint(x: 0.09, y: 0)
  static let undersideControl2 = CGPoint(x: -0.15, y: -0.01)
  static let notchInset: CGFloat = 0.38
  static let notchSoftness: CGFloat = 0.075
  static let tipRoundness: CGFloat = 0.02

  /// The corner radius actually rendered for a body of `size`; matches Core Animation's clamping.
  public static func effectiveRadius(cornerRadius: CGFloat, size: CGSize) -> CGFloat {
    max(0, min(cornerRadius, size.width / 2, size.height / 2))
  }

  /// How far the tail tip reaches past the bubble's side edge.
  public static func exposedWidth(radius: CGFloat) -> CGFloat {
    tip.x * radius
  }

  /// Tail for the bottom corner of a body whose bottom corner on `side` sits at `corner`.
  public static func tailPath(corner: CGPoint, radius: CGFloat, side: Side) -> CGPath {
    let path = CGMutablePath()
    guard radius > 0 else { return path }
    let direction: CGFloat = side == .trailing ? 1 : -1
    let outline = side == .trailing ? localOutline : localOutline.reversed()
    outline.append(to: path) { local in
      CGPoint(x: corner.x + direction * local.x * radius, y: corner.y + local.y * radius)
    }
    return path
  }

  /// Rounded body plus tail, both clockwise so the non-zero rule fills their union.
  public static func bubblePath(body: CGRect, cornerRadius: CGFloat, side: Side?) -> CGPath {
    let radius = effectiveRadius(cornerRadius: cornerRadius, size: body.size)
    let path = CGMutablePath()
    guard body.width > 0, body.height > 0 else { return path }
    path.move(to: CGPoint(x: body.minX + radius, y: body.minY))
    path.addArc(
      tangent1End: CGPoint(x: body.maxX, y: body.minY),
      tangent2End: CGPoint(x: body.maxX, y: body.maxY),
      radius: radius
    )
    path.addArc(
      tangent1End: CGPoint(x: body.maxX, y: body.maxY),
      tangent2End: CGPoint(x: body.minX, y: body.maxY),
      radius: radius
    )
    path.addArc(
      tangent1End: CGPoint(x: body.minX, y: body.maxY),
      tangent2End: CGPoint(x: body.minX, y: body.minY),
      radius: radius
    )
    path.addArc(
      tangent1End: CGPoint(x: body.minX, y: body.minY),
      tangent2End: CGPoint(x: body.maxX, y: body.minY),
      radius: radius
    )
    path.closeSubpath()

    if let side {
      let corner = CGPoint(x: side == .trailing ? body.maxX : body.minX, y: body.maxY)
      path.addPath(tailPath(corner: corner, radius: radius, side: side))
    }
    return path
  }

  /// Trailing tail at unit radius, clockwise, with the corner at the origin.
  static let localOutline: Outline = {
    func offset(_ point: CGPoint, toward target: CGPoint, by distance: CGFloat) -> CGPoint {
      let dx = target.x - point.x
      let dy = target.y - point.y
      let length = max(hypot(dx, dy), .ulpOfOne)
      return CGPoint(x: point.x + dx / length * distance, y: point.y + dy / length * distance)
    }

    let sideControl2 = CGPoint(x: 0, y: -sideControl2Height)
    let tipStart = offset(tip, toward: sideControl2, by: tipRoundness)
    let tipEnd = offset(tip, toward: undersideControl1, by: tipRoundness)

    // The notch sits on the corner arc (center at (-1, -1)) and is rounded by
    // cutting it with a quad that ends further along the arc.
    let center = CGPoint(x: -1, y: -1)
    let notch = CGPoint(
      x: -notchInset,
      y: center.y + (1 - pow(1 - notchInset, 2)).squareRoot()
    )
    let softness = min(notchSoftness, hypot(undersideControl2.x - notch.x, undersideControl2.y - notch.y) * 0.9)
    let notchStart = offset(notch, toward: undersideControl2, by: softness)
    let notchAngle = atan2(notch.y - center.y, notch.x - center.x) + softness
    let notchEnd = CGPoint(x: center.x + cos(notchAngle), y: center.y + sin(notchAngle))

    let start = CGPoint(x: 0, y: -1)
    return Outline(start: start, segments: [
      .line(CGPoint(x: 0, y: -shoulderHeight)),
      .cubic(CGPoint(x: 0, y: -sideControl1Height), sideControl2, tipStart),
      .quad(tip, tipEnd),
      .cubic(undersideControl1, undersideControl2, notchStart),
      .quad(notch, notchEnd),
      .line(center),
      .line(start),
    ])
  }()

  struct Outline {
    enum Segment {
      case line(CGPoint)
      case quad(CGPoint, CGPoint)
      case cubic(CGPoint, CGPoint, CGPoint)

      var end: CGPoint {
        switch self {
        case let .line(end), let .quad(_, end), let .cubic(_, _, end): end
        }
      }
    }

    let start: CGPoint
    let segments: [Segment]

    func reversed() -> Outline {
      var starts = [start]
      for segment in segments.dropLast() {
        starts.append(segment.end)
      }
      let reversedSegments: [Segment] = zip(segments, starts).reversed().map { segment, segmentStart in
        switch segment {
        case .line: .line(segmentStart)
        case let .quad(control, _): .quad(control, segmentStart)
        case let .cubic(control1, control2, _): .cubic(control2, control1, segmentStart)
        }
      }
      return Outline(start: segments.last?.end ?? start, segments: reversedSegments)
    }

    func append(to path: CGMutablePath, transform: (CGPoint) -> CGPoint) {
      path.move(to: transform(start))
      for segment in segments {
        switch segment {
        case let .line(end):
          path.addLine(to: transform(end))
        case let .quad(control, end):
          path.addQuadCurve(to: transform(end), control: transform(control))
        case let .cubic(control1, control2, end):
          path.addCurve(to: transform(end), control1: transform(control1), control2: transform(control2))
        }
      }
      path.closeSubpath()
    }
  }
}
