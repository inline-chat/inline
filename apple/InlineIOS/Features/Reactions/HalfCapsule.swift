//import SwiftUI
//
///// A shape representing half of a capsule (pill) with either the left or right side rounded.
///// Useful for creating pill-like ends that can be attached to a straight edge.
//struct HalfCapsule: Shape {
//  enum Side {
//    case left
//    case right
//  }
//
//  let side: Side
//
//  func path(in rect: CGRect) -> Path {
//    var path = Path()
//    let radius = rect.height / 2
//
//    switch side {
//    case .left:
//      // Start from top center of the left semicircle
//      path.move(to: CGPoint(x: radius, y: rect.minY))
//      // Draw right edge
//      path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
//      path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
//      // Draw back to start of left semicircle
//      path.addLine(to: CGPoint(x: radius, y: rect.maxY))
//      // Draw the left semicircle
//      path.addArc(
//        center: CGPoint(x: radius, y: rect.midY),
//        radius: radius,
//        startAngle: Angle(degrees: 90),
//        endAngle: Angle(degrees: 270),
//        clockwise: false
//      )
//      
//    case .right:
//      // Start from top left
//      path.move(to: CGPoint(x: rect.minX, y: rect.minY))
//      // Draw to start of right semicircle
//      path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.minY))
//      // Draw the right semicircle
//      path.addArc(
//        center: CGPoint(x: rect.maxX - radius, y: rect.midY),
//        radius: radius,
//        startAngle: Angle(degrees: -90),
//        endAngle: Angle(degrees: 90),
//        clockwise: false
//      )
//      // Draw left edge back
//      path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
//    }
//
//    path.closeSubpath()
//    return path
//  }
//}
