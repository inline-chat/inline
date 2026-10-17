import InlineUI
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
  static let cornerRadius: CGFloat = 18
  static let minimumBodyHeight: CGFloat = cornerRadius * 2

  // Whole points keep the nine-slice fill's caps on the pixel grid, so the animated
  // fill matches the canonical path exactly.
  private static let fullSizeExposedTailWidth = MessageBubbleTailGeometry.exposedWidth(radius: cornerRadius)
    .rounded(.up)

  static func tailWidth(for side: MessageBubbleTailSide) -> CGFloat {
    side == .none ? 0 : fullSizeExposedTailWidth
  }

  static func path(in rect: CGRect, side: MessageBubbleTailSide) -> UIBezierPath {
    let contentRect = contentRect(for: side, in: rect).intersection(rect)
    guard !contentRect.isNull, contentRect.width > 0, contentRect.height > 0 else {
      return UIBezierPath()
    }

    return UIBezierPath(cgPath: MessageBubbleTailGeometry.bubblePath(
      body: contentRect,
      cornerRadius: cornerRadius,
      side: side.tailGeometrySide
    ))
  }

  static func tailPathOnly(
    for side: MessageBubbleTailSide,
    in rect: CGRect
  ) -> UIBezierPath? {
    let contentRect = contentRect(for: side, in: rect)
    guard let tailSide = side.tailGeometrySide, !contentRect.isNull, contentRect.width > 0,
          contentRect.height > 0
    else {
      return nil
    }

    let radius = MessageBubbleTailGeometry.effectiveRadius(cornerRadius: cornerRadius, size: contentRect.size)
    let corner = CGPoint(x: tailSide == .trailing ? contentRect.maxX : contentRect.minX, y: contentRect.maxY)
    return UIBezierPath(cgPath: MessageBubbleTailGeometry.tailPath(corner: corner, radius: radius, side: tailSide))
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

  // Short bubbles clamp the corner radius to half their height, and the tail scales
  // with it, so the reserved tail width shrinks the same way.
  private static func renderScale(in rect: CGRect) -> CGFloat {
    min(max(rect.height / minimumBodyHeight, 0), 1)
  }
}

private extension MessageBubbleTailSide {
  var tailGeometrySide: MessageBubbleTailGeometry.Side? {
    switch self {
    case .none: nil
    case .leading: .leading
    case .trailing: .trailing
    }
  }
}
