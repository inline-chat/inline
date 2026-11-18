/**
 * Usage keys and skin tones. Small and data-free, so the quick reaction row
 * and the usage store can use them before the emoji data loads.
 *
 * Mac: `EmojiUsageKey` (`EmojiAutocomplete.swift` lines 499-516) and
 * `EmojiSkinTone` (`apple/InlineUI/Sources/TextProcessing/EmojiPickerData.swift`
 * lines 40-70).
 */

/** The user's preferred skin tone. Raw values are the Mac's (`EmojiSkinTone.rawValue`), so a stored value reads the same. */
export type SkinTone = "standard" | "light" | "mediumLight" | "medium" | "mediumDark" | "dark"

export const SKIN_TONES: readonly SkinTone[] = ["standard", "light", "mediumLight", "medium", "mediumDark", "dark"]

/** The Fitzpatrick modifier of each tone (U+1F3FB to U+1F3FF); none for `standard`. */
export const SKIN_TONE_MODIFIERS: Readonly<Record<SkinTone, string>> = {
  standard: "",
  light: "\u{1F3FB}",
  mediumLight: "\u{1F3FC}",
  medium: "\u{1F3FD}",
  mediumDark: "\u{1F3FE}",
  dark: "\u{1F3FF}",
}

/** Names for the tone selector. */
export const SKIN_TONE_LABELS: Readonly<Record<SkinTone, string>> = {
  standard: "Default skin tone",
  light: "Light skin tone",
  mediumLight: "Medium-light skin tone",
  medium: "Medium skin tone",
  mediumDark: "Medium-dark skin tone",
  dark: "Dark skin tone",
}

export const isSkinTone = (value: unknown): value is SkinTone => typeof value === "string" && (SKIN_TONES as readonly string[]).includes(value)

const LIGHT = "\u{1F3FB}"
const toneModifiers = /[\u{1F3FB}-\u{1F3FF}]/gu
const toneModifier = /[\u{1F3FB}-\u{1F3FF}]/u
const presentationSelector = /️/g

/** Whether the emoji carries a skin tone modifier. */
export const containsSkinTone = (emoji: string): boolean => toneModifier.test(emoji)

/** Strips skin tone modifiers and VS16 so 👍🏽, 👍 and ❤ / ❤️ share one key (`EmojiUsageKey.make`). */
export const usageKey = (emoji: string): string => emoji.replace(toneModifiers, "").replace(presentationSelector, "")

/**
 * How a base emoji takes a tone: `""` when it does not, `"1"` when the
 * modifier goes right after its first code point (dropping a VS16 there,
 * which is how most do it), or the light-tone sequence itself, whose U+1F3FB
 * marks every place a tone goes (🧑🏻‍🤝‍🧑🏻). This is the data's tone field.
 */
export type ToneTemplate = string

/** The default way a modifier attaches: after the first code point, replacing a VS16 there. */
export const insertModifier = (base: string, modifier: string): string => {
  const first = base.codePointAt(0)
  if (first === undefined) return base
  const head = String.fromCodePoint(first)
  let rest = base.slice(head.length)
  if (rest.startsWith("️")) rest = rest.slice(1)
  return head + modifier + rest
}

/** The light-tone form a template stands for. */
export const lightVariant = (base: string, template: ToneTemplate): string | undefined =>
  template === "" ? undefined : template === "1" ? insertModifier(base, LIGHT) : template

/**
 * The emoji in a tone. Unchanged for `standard`, for emoji that already carry
 * a tone (an explicit choice wins, as on the Mac) and for emoji without a
 * template.
 */
export const applySkinTone = (emoji: string, tone: SkinTone, template: ToneTemplate | undefined): string => {
  if (tone === "standard" || !template || containsSkinTone(emoji)) return emoji
  const light = lightVariant(emoji, template)
  return light === undefined ? emoji : light.replaceAll(LIGHT, SKIN_TONE_MODIFIERS[tone])
}
