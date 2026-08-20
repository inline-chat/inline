import SwiftUI
import UIKit

enum MessageBubbleTailSide: Equatable {
  case none
  case leading
  case trailing
}

struct MessageBubbleShape: Shape {
  let side: MessageBubbleTailSide

  func path(in rect: CGRect) -> SwiftUI.Path {
    SwiftUI.Path(MessageBubbleGeometry.path(in: rect, side: side).cgPath)
  }
}

enum MessageBubbleGeometry {
  // Cropped from the trailing-side full-bubble SVG. `sourceBubbleEdgeX` is the
  // bubble edge the visible tail tucks under before mirroring for leading tails.
  private static let sourceSize = CGSize(width: 37, height: 52.4)
  private static let sourceBubbleEdgeX: CGFloat = 19.5183
  private static let sourceTailBottomY: CGFloat = 51.2853

  static let cornerRadius: CGFloat = 18
  static let minimumBodyHeight: CGFloat = cornerRadius * 2

  private static let fullSizeTailDrawScale = cornerRadius / sourceTailBottomY
  private static let fullSizeExposedTailWidth =
    (sourceSize.width - sourceBubbleEdgeX) * fullSizeTailDrawScale

  static func tailWidth(for side: MessageBubbleTailSide) -> CGFloat {
    side == .none ? 0 : fullSizeExposedTailWidth
  }

  static func path(in rect: CGRect, side: MessageBubbleTailSide) -> UIBezierPath {
    let contentRect = contentRect(for: side, in: rect).intersection(rect)
    guard !contentRect.isNull, contentRect.width > 0, contentRect.height > 0 else {
      return UIBezierPath()
    }

    let path = roundedBodyPath(in: contentRect)
    guard side != .none else { return path }
    guard let tailRect = tailRect(for: side, contentRect: contentRect) else { return path }

    path.append(tailPath(for: side, in: tailRect))
    return path
  }

  static func tailPathOnly(
    for side: MessageBubbleTailSide,
    in rect: CGRect
  ) -> UIBezierPath? {
    let contentRect = contentRect(for: side, in: rect)
    guard side != .none, !contentRect.isNull, contentRect.width > 0, contentRect.height > 0 else {
      return nil
    }
    guard let tailRect = tailRect(for: side, contentRect: contentRect) else { return nil }

    return tailPath(for: side, in: tailRect)
  }

  static func contentRect(
    for side: MessageBubbleTailSide,
    in rect: CGRect
  ) -> CGRect {
    let tailWidth = tailWidth(for: side) * renderScale(in: rect)
    return rect.inset(by: UIEdgeInsets(
      top: 0,
      left: side == .leading ? tailWidth : 0,
      bottom: 0,
      right: side == .trailing ? tailWidth : 0
    ))
  }

  private static func roundedBodyPath(in rect: CGRect) -> UIBezierPath {
    let radius = min(cornerRadius, rect.width / 2, rect.height / 2)
    let control = radius * 0.552_284_749_8
    let path = UIBezierPath()

    path.move(to: CGPoint(x: rect.minX + radius, y: rect.minY))
    path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.minY))
    path.addCurve(
      to: CGPoint(x: rect.maxX, y: rect.minY + radius),
      controlPoint1: CGPoint(x: rect.maxX - radius + control, y: rect.minY),
      controlPoint2: CGPoint(x: rect.maxX, y: rect.minY + radius - control)
    )
    path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
    path.addCurve(
      to: CGPoint(x: rect.maxX - radius, y: rect.maxY),
      controlPoint1: CGPoint(x: rect.maxX, y: rect.maxY - radius + control),
      controlPoint2: CGPoint(x: rect.maxX - radius + control, y: rect.maxY)
    )
    path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
    path.addCurve(
      to: CGPoint(x: rect.minX, y: rect.maxY - radius),
      controlPoint1: CGPoint(x: rect.minX + radius - control, y: rect.maxY),
      controlPoint2: CGPoint(x: rect.minX, y: rect.maxY - radius + control)
    )
    path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radius))
    path.addCurve(
      to: CGPoint(x: rect.minX + radius, y: rect.minY),
      controlPoint1: CGPoint(x: rect.minX, y: rect.minY + radius - control),
      controlPoint2: CGPoint(x: rect.minX + radius - control, y: rect.minY)
    )
    path.close()
    return path
  }

  private static func tailRect(
    for side: MessageBubbleTailSide,
    contentRect: CGRect
  ) -> CGRect? {
    let renderScale = renderScale(in: contentRect)
    let tailDrawScale = fullSizeTailDrawScale * renderScale
    let exposedTailWidth = fullSizeExposedTailWidth * renderScale
    let drawSize = CGSize(
      width: sourceSize.width * tailDrawScale,
      height: sourceSize.height * tailDrawScale
    )
    // The source tail's top edge is scaled to the shared corner radius, so this
    // lands its shoulder exactly on the rounded body's vertical tangent.
    let tailY = contentRect.maxY - sourceTailBottomY * tailDrawScale

    switch side {
    case .none:
      return nil
    case .leading:
      return CGRect(
        x: contentRect.minX - exposedTailWidth,
        y: tailY,
        width: drawSize.width,
        height: drawSize.height
      )
    case .trailing:
      return CGRect(
        x: contentRect.maxX + exposedTailWidth - drawSize.width,
        y: tailY,
        width: drawSize.width,
        height: drawSize.height
      )
    }
  }

  private static func renderScale(in rect: CGRect) -> CGFloat {
    min(max(rect.height / minimumBodyHeight, 0), 1)
  }

  private static func tailPath(
    for side: MessageBubbleTailSide,
    in rect: CGRect
  ) -> UIBezierPath {
    let scaleX = rect.width / sourceSize.width
    let scaleY = rect.height / sourceSize.height

    func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
      let resolvedX: CGFloat = switch side {
      case .leading:
        rect.maxX - x * scaleX
      case .none, .trailing:
        rect.minX + x * scaleX
      }
      return CGPoint(x: resolvedX, y: rect.minY + y * scaleY)
    }

    let path = UIBezierPath()
    path.move(to: point(19.4761, 6.9846))
    path.addCurve(
      to: point(19.5183, 0),
      controlPoint1: point(19.5041, 6.3302),
      controlPoint2: point(19.5183, 0.6611)
    )
    path.addLine(to: point(0, 0))
    path.addLine(to: point(0, 39.8152))
    path.addCurve(
      to: point(36.1476, 50.9938),
      controlPoint1: point(8.3867, 48.2023),
      controlPoint2: point(22.1067, 52.3205)
    )
    path.addCurve(
      to: point(36.5785, 50.7275),
      controlPoint1: point(36.3267, 50.9769),
      controlPoint2: point(36.4868, 50.878)
    )
    path.addCurve(
      to: point(36.3805, 49.9764),
      controlPoint1: point(36.7373, 50.4669),
      controlPoint2: point(36.6487, 50.1307)
    )
    path.addLine(to: point(35.3668, 49.3821))
    path.addCurve(
      to: point(22.3321, 37.0489),
      controlPoint1: point(28.7234, 45.413),
      controlPoint2: point(24.3785, 41.3021)
    )
    path.addCurve(
      to: point(19.4761, 6.9846),
      controlPoint1: point(20.1278, 32.4675),
      controlPoint2: point(19.1757, 22.4468)
    )
    path.close()
    return side == .trailing ? path.reversing() : path
  }
}
