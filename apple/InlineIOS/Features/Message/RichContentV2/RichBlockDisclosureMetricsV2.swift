import CoreGraphics

/// The planner and the retained disclosure view use the same accessory geometry.
enum RichBlockDisclosureMetricsV2 {
  static func accessoryWidth(hasActivity: Bool) -> CGFloat {
    14 + 4 + (hasActivity ? 14 + 5 : 0)
  }

  struct Layout {
    let title: CGRect
    let chevron: CGRect
    let activity: CGRect?
  }

  static func titleViewportWidth(containerWidth: CGFloat, hasActivity: Bool) -> CGFloat {
    max(1, layout(
      bounds: CGRect(x: 0, y: 0, width: max(1, containerWidth), height: 14),
      isRTL: false, hasActivity: hasActivity
    ).title.width)
  }

  static func layout(bounds: CGRect, isRTL: Bool, hasActivity: Bool) -> Layout {
    let width = max(0, bounds.width)
    let height = max(0, bounds.height)
    let chevronWidth = min(14, max(0, width - 1))
    let chevronGap = min(4, max(0, width - chevronWidth - 1))
    let iconWidth = hasActivity ? min(14, max(0, width - chevronWidth - chevronGap - 1)) : 0
    let iconGap = iconWidth > 0 ? min(5, max(0, width - chevronWidth - chevronGap - iconWidth - 1)) : 0
    let titleWidth = max(0, width - chevronWidth - chevronGap - iconWidth - iconGap)
    let chevronSide = min(chevronWidth, height)
    let iconSide = min(iconWidth, height)
    let titleX = isRTL ? bounds.minX + chevronWidth + chevronGap : bounds.minX + iconWidth + iconGap
    return Layout(
      title: CGRect(x: titleX, y: bounds.minY, width: titleWidth, height: height),
      chevron: CGRect(
        x: isRTL ? bounds.minX : bounds.maxX - chevronWidth,
        y: bounds.midY - chevronSide / 2,
        width: chevronSide, height: chevronSide
      ),
      activity: iconWidth > 0 ? CGRect(
        x: isRTL ? bounds.maxX - iconWidth : bounds.minX,
        y: bounds.midY - iconSide / 2,
        width: iconSide, height: iconSide
      ) : nil
    )
  }
}
