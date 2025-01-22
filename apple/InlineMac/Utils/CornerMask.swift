import AppKit

enum ViewCorner: CaseIterable {
  case topLeft
  case topRight
  case bottomLeft
  case bottomRight
}

struct CornerRadius {
  let corner: ViewCorner
  let radius: CGFloat
  
  static func radius(_ radius: CGFloat, for corner: ViewCorner) -> CornerRadius {
    CornerRadius(corner: corner, radius: radius)
  }
}

func applyCornerMask(to view: NSView, corners: [CornerRadius]) {
  view.wantsLayer = true
  view.layer?.masksToBounds = true
  
  let bounds = view.bounds
  let maskLayer = CAShapeLayer()
  let path = CGMutablePath()
  
  // Helper function to get radius for a specific corner
  func radius(for corner: ViewCorner) -> CGFloat {
    corners.first(where: { $0.corner == corner })?.radius ?? 0
  }
  
  // Get radius for each corner
  let topLeft = radius(for: .topLeft)
  let topRight = radius(for: .topRight)
  let bottomRight = radius(for: .bottomRight)
  let bottomLeft = radius(for: .bottomLeft)
  
  // Top-left corner
  path.move(to: CGPoint(x: topLeft, y: bounds.maxY))
  if topLeft > 0 {
    path.addArc(
      center: CGPoint(x: topLeft, y: bounds.maxY - topLeft),
      radius: topLeft,
      startAngle: .pi / 2,
      endAngle: .pi,
      clockwise: false
    )
  }
  
  // Left edge and bottom-left corner
  path.addLine(to: CGPoint(x: 0, y: bottomLeft))
  if bottomLeft > 0 {
    path.addArc(
      center: CGPoint(x: bottomLeft, y: bottomLeft),
      radius: bottomLeft,
      startAngle: .pi,
      endAngle: .pi * 3 / 2,
      clockwise: false
    )
  }
  
  // Bottom edge and bottom-right corner
  path.addLine(to: CGPoint(x: bounds.maxX - bottomRight, y: 0))
  if bottomRight > 0 {
    path.addArc(
      center: CGPoint(x: bounds.maxX - bottomRight, y: bottomRight),
      radius: bottomRight,
      startAngle: .pi * 3 / 2,
      endAngle: 0,
      clockwise: false
    )
  }
  
  // Right edge and top-right corner
  path.addLine(to: CGPoint(x: bounds.maxX, y: bounds.maxY - topRight))
  if topRight > 0 {
    path.addArc(
      center: CGPoint(x: bounds.maxX - topRight, y: bounds.maxY - topRight),
      radius: topRight,
      startAngle: 0,
      endAngle: .pi / 2,
      clockwise: false
    )
  }
  
  path.closeSubpath()
  maskLayer.path = path
  view.layer?.mask = maskLayer
}
