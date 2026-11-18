/**
 * Typeahead for lists (APG): typing characters moves to the next item whose
 * label starts with them. Repeating one character cycles through the items
 * that start with it. The buffer clears after a pause.
 */

import { type Clock, systemClock, Timer } from "./clock"

export type TypeaheadItem = { readonly id: string; readonly text: string; readonly disabled?: boolean }

export const normalizeText = (text: string): string =>
  text
    .normalize("NFD")
    .replace(/[̀-ͯ]/g, "")
    .trim()
    .toLocaleLowerCase()

/**
 * The item matching `search`, searching from the item after `current` and
 * wrapping. A multi-character search may stay on `current` while it still matches.
 */
export const findTypeaheadMatch = (
  items: readonly TypeaheadItem[],
  search: string,
  current: string | null,
): string | null => {
  const query = normalizeText(search)
  if (!query) return null
  const candidates = items.filter((item) => !item.disabled)
  if (candidates.length === 0) return null
  const repeated = query.length > 1 && [...query].every((char) => char === query[0])
  const needle = repeated ? query[0]! : query
  const start = candidates.findIndex((item) => item.id === current)
  // A growing query keeps the current item while it still matches.
  if (!repeated && query.length > 1 && start >= 0) {
    const currentItem = candidates[start]!
    if (normalizeText(currentItem.text).startsWith(needle)) return currentItem.id
  }
  for (let offset = 1; offset <= candidates.length; offset++) {
    const item = candidates[(Math.max(start, -1) + offset + candidates.length) % candidates.length]
    if (item && normalizeText(item.text).startsWith(needle)) return item.id
  }
  return null
}

export type TypeaheadOptions = { clock?: Clock; timeout?: number }

export class Typeahead {
  #buffer = ""
  readonly #timer: Timer
  readonly #timeout: number

  constructor(options: TypeaheadOptions = {}) {
    this.#timer = new Timer(options.clock ?? systemClock)
    this.#timeout = options.timeout ?? 500
  }

  /** True while a search is in progress, so Space is a character rather than activation. */
  get active(): boolean {
    return this.#buffer.length > 0
  }

  get buffer(): string {
    return this.#buffer
  }

  /** Add a character and return the matching item, if any. */
  type(char: string, items: readonly TypeaheadItem[], current: string | null): string | null {
    this.#buffer += char
    this.#timer.start(this.#timeout, () => {
      this.#buffer = ""
    })
    return findTypeaheadMatch(items, this.#buffer, current)
  }

  reset(): void {
    this.#timer.stop()
    this.#buffer = ""
  }
}
