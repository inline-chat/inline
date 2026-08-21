import AppKit

enum RichBlockDisclosureMetrics {
  static let preferredChevronSide: CGFloat = 14
  static let titleChevronGap: CGFloat = 4

  struct HorizontalLayout: Equatable {
    let titleFrame: CGRect
    let chevronFrame: CGRect
  }

  static func titleViewportWidth(containerWidth: CGFloat) -> CGFloat {
    let width = max(1, containerWidth)
    let chevronWidth = min(preferredChevronSide, max(0, width - 1))
    let gap = min(titleChevronGap, max(0, width - chevronWidth - 1))
    return max(1, width - chevronWidth - gap)
  }

  static func horizontalLayout(
    bounds: CGRect,
    intrinsicTitleWidth: CGFloat,
    isRTL: Bool
  ) -> HorizontalLayout {
    let width = max(0, bounds.width)
    let chevronWidth = min(preferredChevronSide, max(0, width - 1))
    let availableGap = min(titleChevronGap, max(0, width - chevronWidth - 1))
    let viewportWidth = max(0, width - chevronWidth - availableGap)
    let titleWidth = min(max(0, intrinsicTitleWidth), viewportWidth)
    let gap = titleWidth > 0 && chevronWidth > 0 ? availableGap : 0
    let chevronSide = min(chevronWidth, max(0, bounds.height))
    let chevronY = bounds.minY + floor((bounds.height - chevronSide) / 2)

    if isRTL {
      let groupWidth = chevronSide + gap + titleWidth
      let groupX = bounds.maxX - groupWidth
      return .init(
        titleFrame: CGRect(
          x: groupX + chevronSide + gap,
          y: bounds.minY,
          width: titleWidth,
          height: bounds.height
        ),
        chevronFrame: CGRect(
          x: groupX,
          y: chevronY,
          width: chevronSide,
          height: chevronSide
        )
      )
    }

    return .init(
      titleFrame: CGRect(
        x: bounds.minX,
        y: bounds.minY,
        width: titleWidth,
        height: bounds.height
      ),
      chevronFrame: CGRect(
        x: bounds.minX + titleWidth + gap,
        y: chevronY,
        width: chevronSide,
        height: chevronSide
      )
    )
  }
}
