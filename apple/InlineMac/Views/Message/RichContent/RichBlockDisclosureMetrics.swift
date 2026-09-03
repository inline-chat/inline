import AppKit

enum RichBlockDisclosureMetrics {
  static let preferredChevronSide: CGFloat = 14
  static let titleChevronGap: CGFloat = 4
  static let activityIconSide: CGFloat = 14
  static let activityTitleGap: CGFloat = 5

  struct HorizontalLayout: Equatable {
    let titleFrame: CGRect
    let chevronFrame: CGRect
    let activityIconFrame: CGRect?
  }

  static func titleViewportWidth(containerWidth: CGFloat, hasActivityIcon: Bool = false) -> CGFloat {
    let width = max(1, containerWidth)
    let chevronWidth = min(preferredChevronSide, max(0, width - 1))
    let gap = min(titleChevronGap, max(0, width - chevronWidth - 1))
    let activityWidth = hasActivityIcon ? activityIconSide + activityTitleGap : 0
    return max(1, width - chevronWidth - gap - activityWidth)
  }

  static func horizontalLayout(
    bounds: CGRect,
    intrinsicTitleWidth: CGFloat,
    isRTL: Bool,
    hasActivityIcon: Bool = false
  ) -> HorizontalLayout {
    let width = max(0, bounds.width)
    let chevronWidth = min(preferredChevronSide, max(0, width - 1))
    let availableGap = min(titleChevronGap, max(0, width - chevronWidth - 1))
    let iconWidth = hasActivityIcon ? min(activityIconSide, max(0, width - chevronWidth - availableGap - 1)) : 0
    let iconGap = iconWidth > 0 ? min(activityTitleGap, max(0, width - chevronWidth - availableGap - iconWidth - 1)) : 0
    let viewportWidth = max(0, width - chevronWidth - availableGap - iconWidth - iconGap)
    let titleWidth = min(max(0, intrinsicTitleWidth), viewportWidth)
    let gap = titleWidth > 0 && chevronWidth > 0 ? availableGap : 0
    let chevronSide = min(chevronWidth, max(0, bounds.height))
    let chevronY = bounds.minY + floor((bounds.height - chevronSide) / 2)

    if isRTL {
      let groupWidth = chevronSide + gap + titleWidth + iconGap + iconWidth
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
        ),
        activityIconFrame: iconWidth > 0 ? CGRect(
          x: groupX + chevronSide + gap + titleWidth + iconGap,
          y: bounds.minY + floor((bounds.height - iconWidth) / 2),
          width: iconWidth,
          height: iconWidth
        ) : nil
      )
    }

    return .init(
      titleFrame: CGRect(
        x: bounds.minX + iconWidth + iconGap,
        y: bounds.minY,
        width: titleWidth,
        height: bounds.height
      ),
      chevronFrame: CGRect(
        x: bounds.minX + iconWidth + iconGap + titleWidth + gap,
        y: chevronY,
        width: chevronSide,
        height: chevronSide
      ),
      activityIconFrame: iconWidth > 0 ? CGRect(
        x: bounds.minX,
        y: bounds.minY + floor((bounds.height - iconWidth) / 2),
        width: iconWidth,
        height: iconWidth
      ) : nil
    )
  }
}
