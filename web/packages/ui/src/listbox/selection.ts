/**
 * Selection over ordered keys, with the desktop model: click replaces, the
 * platform modifier toggles, Shift extends a range from the anchor. A Shift
 * range is added to what was selected when the anchor was set, so
 * Cmd-click, Cmd-click, Shift-click builds selections the way Finder does.
 */

import { type ReadSignal, type Signal, signal } from "@inline/reactive"

export type SelectionMode = "none" | "single" | "multiple"

export type SelectionOptions = {
  mode: SelectionMode
  initial?: Iterable<string>
  onChange?: (selected: ReadonlySet<string>) => void
}

const sameSet = (a: ReadonlySet<string>, b: ReadonlySet<string>) => a.size === b.size && [...a].every((key) => b.has(key))

export class SelectionModel {
  readonly mode: SelectionMode
  readonly #selected: Signal<ReadonlySet<string>>
  readonly #onChange: SelectionOptions["onChange"]
  #anchor: string | null = null
  #base: ReadonlySet<string> = new Set()

  readonly selected: ReadSignal<ReadonlySet<string>>

  constructor(options: SelectionOptions) {
    this.mode = options.mode
    const initial = new Set(options.mode === "none" ? [] : (options.initial ?? []))
    if (options.mode === "single" && initial.size > 1) {
      const first = [...initial][0]!
      initial.clear()
      initial.add(first)
    }
    this.#selected = signal<ReadonlySet<string>>(initial, { equals: sameSet })
    this.selected = this.#selected
    this.#onChange = options.onChange
    this.#anchor = [...initial][0] ?? null
    this.#base = initial
  }

  get anchor(): string | null {
    return this.#anchor
  }

  isSelected(key: string): boolean {
    return this.#selected.peek().has(key)
  }

  #write(next: ReadonlySet<string>): void {
    if (this.mode === "none") return
    const before = this.#selected.peek()
    this.#selected.set(next)
    if (!sameSet(before, next)) this.#onChange?.(next)
  }

  /** Select exactly `key` and make it the anchor. */
  replace(key: string): void {
    this.#anchor = key
    this.#base = new Set()
    this.#write(new Set([key]))
  }

  /** Toggle `key` (multiple) or select it (single). Makes it the anchor. */
  toggle(key: string): void {
    if (this.mode !== "multiple") {
      this.replace(key)
      return
    }
    const next = new Set(this.#selected.peek())
    if (next.has(key)) next.delete(key)
    else next.add(key)
    this.#anchor = key
    this.#base = new Set([...next].filter((item) => item !== key))
    this.#write(next)
  }

  /** Select the range from the anchor to `key` in `order`, on top of the selection the anchor was set on. */
  extendTo(key: string, order: readonly string[]): void {
    if (this.mode !== "multiple" || this.#anchor === null) {
      this.replace(key)
      return
    }
    const from = order.indexOf(this.#anchor)
    const to = order.indexOf(key)
    if (from < 0 || to < 0) {
      this.replace(key)
      return
    }
    const [low, high] = from <= to ? [from, to] : [to, from]
    const next = new Set(this.#base)
    for (let index = low; index <= high; index++) next.add(order[index]!)
    this.#write(next)
  }

  selectAll(order: readonly string[]): void {
    if (this.mode !== "multiple") return
    this.#write(new Set(order))
  }

  clear(): void {
    this.#anchor = null
    this.#base = new Set()
    this.#write(new Set())
  }

  set(keys: Iterable<string>): void {
    const next = new Set(keys)
    this.#anchor = [...next][0] ?? null
    this.#base = new Set()
    this.#write(this.mode === "single" ? new Set([...next].slice(0, 1)) : next)
  }
}
