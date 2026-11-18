/**
 * Avatar color and initials, matching the Apple apps
 * (`InlineAvatarStyle` in apple/InlineKit/Sources/InlineAvatarCore), so a
 * person has the same color on every client.
 */

/** sRGB 0..1, the same palette and order as the Apple apps. */
export const avatarPalette: ReadonlyArray<readonly [number, number, number]> = [
  [0.86, 0.15, 0.47],
  [1.0, 0.58, 0.0],
  [0.54, 0.32, 0.92],
  [0.86, 0.64, 0.02],
  [0.0, 0.63, 0.58],
  [0.02, 0.48, 1.0],
  [0.0, 0.72, 0.65],
  [0.2, 0.68, 0.3],
  [0.92, 0.22, 0.2],
  [0.35, 0.34, 0.84],
  [0.12, 0.72, 0.48],
  [0.0, 0.68, 0.86],
]

/** The sum of the seed's UTF-8 bytes modulo the palette size, as on Apple. */
export const avatarPaletteIndex = (seed: string, paletteCount = avatarPalette.length): number => {
  if (paletteCount <= 0) return 0
  let index = 0
  for (const byte of new TextEncoder().encode(seed)) index = (index + byte) % paletteCount
  return index
}

const toCss = ([red, green, blue]: readonly [number, number, number], alpha = 1) =>
  `rgb(${Math.round(red * 255)} ${Math.round(green * 255)} ${Math.round(blue * 255)}${alpha < 1 ? ` / ${alpha}` : ""})`

const lighten = ([red, green, blue]: readonly [number, number, number], amount: number) => {
  const max = Math.max(red, green, blue)
  const min = Math.min(red, green, blue)
  const delta = max - min
  let hue = 0
  let saturation = 0
  let lightness = (max + min) / 2
  if (delta !== 0) {
    saturation = lightness < 0.5 ? delta / (max + min) : delta / (2 - max - min)
    if (max === red) hue = (green - blue) / delta + (green < blue ? 6 : 0)
    else if (max === green) hue = (blue - red) / delta + 2
    else hue = (red - green) / delta + 4
    hue /= 6
  }
  lightness = Math.min(1, Math.max(0, lightness + amount))
  if (saturation === 0) return [lightness, lightness, lightness] as const
  const q = lightness < 0.5 ? lightness * (1 + saturation) : lightness + saturation - lightness * saturation
  const p = 2 * lightness - q
  const component = (value: number) => {
    let t = value
    if (t < 0) t += 1
    if (t > 1) t -= 1
    if (t < 1 / 6) return p + (q - p) * 6 * t
    if (t < 1 / 2) return q
    if (t < 2 / 3) return p + (q - p) * (2 / 3 - t) * 6
    return p
  }
  return [component(hue + 1 / 3), component(hue), component(hue - 1 / 3)] as const
}

export type AvatarStyle = { index: number; background: string; gradientTop: string; border: string }

/** Colors for a seed: a top-lit gradient and a faint border, as on Apple. */
export const avatarStyle = (seed: string): AvatarStyle => {
  const index = avatarPaletteIndex(seed)
  const base = avatarPalette[index]!
  return {
    index,
    background: toCss(base),
    gradientTop: toCss(lighten(base, 0.2)),
    border: toCss(lighten(base, -0.4), 0.1),
  }
}

const trimmed = (value: string | null | undefined) => {
  const result = value?.trim()
  return result ? result : null
}

/**
 * The hashing seed, as `InlineAvatarPresentation.nameSeed` builds it: the
 * first name (else the email's local part, else "User"), then the last name.
 */
export const avatarSeed = (person: { firstName?: string | null; lastName?: string | null; email?: string | null }) => {
  const first = trimmed(person.firstName) ?? trimmed(trimmed(person.email)?.split("@").find(Boolean)) ?? "User"
  const last = trimmed(person.lastName)
  return last ? `${first} ${last}` : first
}

/** Up to two initials, by grapheme so emoji and combining marks stay whole. */
export const initials = (name: string): string => {
  const segmenter = typeof Intl !== "undefined" && "Segmenter" in Intl ? new Intl.Segmenter(undefined, { granularity: "grapheme" }) : null
  const first = (word: string) => (segmenter ? ([...segmenter.segment(word)][0]?.segment ?? "") : (word[0] ?? ""))
  const words = name.trim().split(/\s+/).filter(Boolean)
  if (words.length === 0) return ""
  const letters = words.length === 1 ? first(words[0]!) : first(words[0]!) + first(words[words.length - 1]!)
  return letters.toLocaleUpperCase()
}
