/**
 * Which stored size of a photo to request.
 *
 * `bestPhotoSize` is the Mac's choice (`InlineKit/Models/Media.swift`
 * `bestPhotoSize`): sizes with a source first, then the size class
 * `f > d > c > b > other`, then area, then bytes. The Mac always loads that
 * size and downsamples it.
 *
 * The web asks for less where it can: `photoVariantFor` picks the smallest
 * stored size that covers the box at the device pixel ratio, and falls back
 * to the best size when none does. A row carries no fetch state; the media
 * layer turns the chosen size into a request (`fileUniqueId` through
 * `getFilePart`, or the size's signed `cdnUrl`, which may have expired).
 */

import type { PhotoInfo, PhotoSizeInfo } from "@inline/core-protocol"
import type { Box } from "./layout"

const typeRank = (type: string): number => {
  switch (type) {
    case "f":
      return 4
    case "d":
      return 3
    case "c":
      return 2
    case "b":
      return 1
    default:
      return 0
  }
}

const hasSource = (size: PhotoSizeInfo): boolean => size.cdnUrl !== undefined || size.fileUniqueId !== undefined

const compareBest = (a: PhotoSizeInfo, b: PhotoSizeInfo): number =>
  Number(hasSource(a)) - Number(hasSource(b)) ||
  typeRank(a.type) - typeRank(b.type) ||
  a.width * a.height - b.width * b.height ||
  (a.size ?? 0) - (b.size ?? 0)

/** The Mac's best size. Undefined when the photo has no stored size. */
export const bestPhotoSize = (photo: PhotoInfo | undefined): PhotoSizeInfo | undefined => {
  let best: PhotoSizeInfo | undefined
  for (const size of photo?.sizes ?? []) {
    if (size.type === "s") continue
    if (!best || compareBest(size, best) > 0) best = size
  }
  return best
}

export type PhotoVariantRequest = {
  readonly size: PhotoSizeInfo
  /** True when the size is smaller than the box at this pixel ratio (the best there is). */
  readonly undersized: boolean
}

/**
 * The size to request for a box at a device pixel ratio: the smallest size
 * with a source that covers the box in both dimensions, else the best size.
 */
export const photoVariantFor = (
  photo: PhotoInfo | undefined,
  box: Box,
  pixelRatio = 1,
): PhotoVariantRequest | undefined => {
  const ratio = Number.isFinite(pixelRatio) && pixelRatio > 0 ? pixelRatio : 1
  const needWidth = Math.ceil(box.width * ratio)
  const needHeight = Math.ceil(box.height * ratio)
  let cover: PhotoSizeInfo | undefined
  for (const size of photo?.sizes ?? []) {
    if (size.type === "s" || !hasSource(size)) continue
    const covers = size.width >= needWidth && size.height >= needHeight
    if (covers && (!cover || size.width * size.height < cover.width * cover.height)) cover = size
  }
  if (cover) return { size: cover, undersized: false }
  const best = bestPhotoSize(photo)
  return best ? { size: best, undersized: true } : undefined
}
