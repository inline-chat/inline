import CoreGraphics

/// Rounds geometry to the display's physical pixels.
public struct PixelGrid: Hashable, Sendable {
  public let scale: CGFloat

  public init(scale: CGFloat) {
    self.scale = scale.isFinite && scale >= 1 ? scale : 1
  }

  public func round(_ value: CGFloat) -> CGFloat {
    (value * scale).rounded() / scale
  }

  /// Rounds up, ignoring float noise far below one pixel so exact values stay put.
  public func ceil(_ value: CGFloat) -> CGFloat {
    (value * scale - 0.001).rounded(.up) / scale
  }

  public func floor(_ value: CGFloat) -> CGFloat {
    (value * scale + 0.001).rounded(.down) / scale
  }

  public func round(_ rect: CGRect) -> CGRect {
    let minX = round(rect.minX)
    let minY = round(rect.minY)
    return CGRect(x: minX, y: minY, width: round(rect.maxX) - minX, height: round(rect.maxY) - minY)
  }

  public func isAligned(_ value: CGFloat) -> Bool {
    abs(value * scale - (value * scale).rounded()) < 0.01
  }

  public func isAligned(_ rect: CGRect) -> Bool {
    isAligned(rect.minX) && isAligned(rect.minY) && isAligned(rect.maxX) && isAligned(rect.maxY)
  }
}
