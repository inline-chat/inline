/**
 * Avatar inputs prepared once per name, so rendering a row does no color math
 * or grapheme segmentation (rows are pure; `docs/performance.md`). The kit's
 * `initials` builds an `Intl.Segmenter` per call, and `avatarStyle` hashes
 * and converts colors; both are cached here in a bounded map.
 */

import { avatarStyle, initials, type AvatarStyle } from "@inline/ui"

export type AvatarFace = {
  readonly initials: string
  readonly colors: AvatarStyle
}

const LIMIT = 2048
const faces = new Map<string, AvatarFace>()

/** Initials from `name` on the Apple apps' color for `seed`. */
export const avatarFace = (name: string, seed: string): AvatarFace => {
  const cacheKey = `${seed}\u0000${name}`
  let face = faces.get(cacheKey)
  if (face === undefined) {
    face = { initials: initials(name), colors: avatarStyle(seed) }
    if (faces.size >= LIMIT) {
      // Drop the oldest entry; Map iteration is insertion order.
      const oldest = faces.keys().next()
      if (!oldest.done) faces.delete(oldest.value)
    }
    faces.set(cacheKey, face)
  }
  return face
}

/** For tests. */
export const avatarCacheSize = (): number => faces.size
