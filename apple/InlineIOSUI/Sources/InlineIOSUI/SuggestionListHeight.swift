import CoreGraphics

public func suggestionListHeight(
  itemCount: Int,
  itemHeight: CGFloat,
  maxVisibleItems: Int,
  maxHeight: CGFloat
) -> CGFloat {
  guard itemCount > 0 else { return 0 }

  let visibleItems = min(itemCount, maxVisibleItems)
  let height = CGFloat(visibleItems) * itemHeight
  return min(height, maxHeight)
}
