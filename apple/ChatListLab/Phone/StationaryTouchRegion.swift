import UIKit

/// Touch coordinates inside UIScrollView include its content offset.
enum StationaryTouchRegion {
  static func contains(_ point: CGPoint, in bounds: CGRect) -> Bool {
    bounds.contains(point) && point.x < bounds.minX + 16
  }
}
