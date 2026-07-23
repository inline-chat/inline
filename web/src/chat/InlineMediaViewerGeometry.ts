export type InlineMediaViewerRect = {
  left: number
  top: number
  width: number
  height: number
}

export const containedInlineMediaRect = (
  mediaWidth: number,
  mediaHeight: number,
  viewportWidth: number,
  viewportHeight: number,
  inset = 32,
): InlineMediaViewerRect => {
  const width = Math.max(1, mediaWidth)
  const height = Math.max(1, mediaHeight)
  const availableWidth = Math.max(1, viewportWidth - inset * 2)
  const availableHeight = Math.max(1, viewportHeight - inset * 2)
  const scale = Math.min(
    1,
    availableWidth / width,
    availableHeight / height,
  )
  const fittedWidth = width * scale
  const fittedHeight = height * scale
  return {
    left: (viewportWidth - fittedWidth) / 2,
    top: (viewportHeight - fittedHeight) / 2,
    width: fittedWidth,
    height: fittedHeight,
  }
}
