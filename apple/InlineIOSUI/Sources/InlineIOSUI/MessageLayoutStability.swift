import CoreGraphics

public enum MessageBubbleWidthMode: Equatable, Sendable {
  case contentSizedUpToMaximum
  case fixedMaximum
}

public enum MessageBubbleWidthPolicy {
  public static let maximumWidthFraction: CGFloat = 0.9

  public static func mode(hasLargeURLPreview: Bool) -> MessageBubbleWidthMode {
    hasLargeURLPreview ? .fixedMaximum : .contentSizedUpToMaximum
  }
}

public struct SelfSizingHeightStabilizer: Sendable {
  public struct Instability: Equatable, Sendable {
    public let previousHeight: CGFloat
    public let measuredHeight: CGFloat
    public let stabilizedHeight: CGFloat
  }

  public struct Resolution: Equatable, Sendable {
    public let height: CGFloat
    public let instability: Instability?
    public let isLocked: Bool
  }

  private var measuredWidth: CGFloat?
  private var previousHeight: CGFloat?
  private var lockedHeight: CGFloat?

  public init() {}

  public mutating func reset() {
    measuredWidth = nil
    previousHeight = nil
    lockedHeight = nil
  }

  public mutating func resolve(
    width: CGFloat,
    measuredHeight: CGFloat,
    widthTolerance: CGFloat = 0.5,
    heightTolerance: CGFloat = 0.25
  ) -> Resolution {
    guard width.isFinite, width > 0, measuredHeight.isFinite, measuredHeight > 0 else {
      return Resolution(height: measuredHeight, instability: nil, isLocked: false)
    }

    if let measuredWidth, abs(measuredWidth - width) >= widthTolerance {
      reset()
    }
    self.measuredWidth = width

    if let lockedHeight {
      return Resolution(height: lockedHeight, instability: nil, isLocked: true)
    }

    guard let previousHeight else {
      self.previousHeight = measuredHeight
      return Resolution(height: measuredHeight, instability: nil, isLocked: false)
    }

    guard abs(previousHeight - measuredHeight) >= heightTolerance else {
      self.previousHeight = measuredHeight
      return Resolution(height: measuredHeight, instability: nil, isLocked: false)
    }

    // UICollectionView requires repeated self-sizing passes for the same width and content to
    // converge. If Auto Layout disagrees with its previous result, keep the larger height until
    // the caller resets for new content, width, or traits. Extra space is safer than clipping.
    let stabilizedHeight = max(previousHeight, measuredHeight)
    lockedHeight = stabilizedHeight
    return Resolution(
      height: stabilizedHeight,
      instability: Instability(
        previousHeight: previousHeight,
        measuredHeight: measuredHeight,
        stabilizedHeight: stabilizedHeight
      ),
      isLocked: true
    )
  }
}
