/**
 * Typeahead by title over the whole list, not just the rendered window.
 * Titles are read lazily from the current position onward, so a keystroke
 * usually reads a handful of items, not thousands.
 *
 * Same rules as the kit's `findTypeaheadMatch` (APG): search from the item
 * after the current one and wrap; a growing query stays on the current item
 * while it still matches; repeating one character cycles through the items
 * that start with it.
 */

import { type Clock, normalizeText, systemClock, Timer } from "@inline/ui"

/** The index of the match, or -1. `titleAt` may return undefined for an item that is not loaded. */
export const findTitleMatch = (
  count: number,
  titleAt: (index: number) => string | undefined,
  search: string,
  current: number,
): number => {
  const query = normalizeText(search)
  if (!query || count <= 0) return -1
  const chars = [...query]
  const repeated = chars.length > 1 && chars.every((char) => char === chars[0])
  const needle = repeated ? (chars[0] ?? query) : query
  const matches = (index: number) => normalizeText(titleAt(index) ?? "").startsWith(needle)
  const start = current >= 0 && current < count ? current : -1
  if (!repeated && chars.length > 1 && start >= 0 && matches(start)) return start
  for (let offset = 1; offset <= count; offset++) {
    const index = (start + offset) % count
    if (matches(index)) return index
  }
  return -1
}

export type TitleTypeaheadOptions = { readonly clock?: Clock; readonly timeout?: number }

/** The typed buffer with its pause timeout. */
export class TitleTypeahead {
  #buffer = ""
  readonly #timer: Timer
  readonly #timeout: number

  constructor(options: TitleTypeaheadOptions = {}) {
    this.#timer = new Timer(options.clock ?? systemClock)
    this.#timeout = options.timeout ?? 500
  }

  /** True mid-search, so Space is a character rather than "open". */
  get active(): boolean {
    return this.#buffer.length > 0
  }

  get buffer(): string {
    return this.#buffer
  }

  type(char: string, count: number, titleAt: (index: number) => string | undefined, current: number): number {
    this.#buffer += char
    this.#timer.start(this.#timeout, () => {
      this.#buffer = ""
    })
    return findTitleMatch(count, titleAt, this.#buffer, current)
  }

  reset(): void {
    this.#timer.stop()
    this.#buffer = ""
  }
}
