/**
 * Focus management: tabbable discovery, focus scopes with an optional trap,
 * focus restore on close, and a roving tab index.
 */

import { type ReadSignal, type Signal, signal } from "@inline/reactive"
import { activeElementOf, contains, type Dispose, focusElement, listen } from "./dom"

const candidateSelector = [
  "a[href]",
  "area[href]",
  "button",
  "input",
  "select",
  "textarea",
  "iframe",
  "summary",
  "audio[controls]",
  "video[controls]",
  "[contenteditable]:not([contenteditable='false'])",
  "[tabindex]",
].join(",")

const isHiddenOrInert = (element: Element, root: Element): boolean => {
  for (let node: Element | null = element; node; node = node.parentElement) {
    if (node.hasAttribute("hidden") || (node as HTMLElement).inert) return true
    if (node === root) break
  }
  return false
}

export const isFocusable = (element: Element, root: Element = element): boolean => {
  if (!(element as HTMLElement).focus) return false
  if ((element as HTMLButtonElement).disabled) return false
  if (element instanceof HTMLInputElement && element.type === "hidden") return false
  return !isHiddenOrInert(element, root)
}

const tabIndexOf = (element: Element): number => {
  const value = element.getAttribute("tabindex")
  if (value !== null) {
    const parsed = Number.parseInt(value, 10)
    return Number.isNaN(parsed) ? 0 : parsed
  }
  return (element as HTMLElement).tabIndex ?? 0
}

/** Elements reachable with Tab inside `root`, in tab order. */
export const getTabbables = (root: Element): HTMLElement[] => {
  const candidates = [...root.querySelectorAll<HTMLElement>(candidateSelector)].filter(
    (element) => tabIndexOf(element) >= 0 && isFocusable(element, root),
  )
  // Radio groups take one stop: the checked radio, or the first one.
  const seenGroups = new Set<string>()
  const filtered = candidates.filter((element) => {
    if (!(element instanceof HTMLInputElement) || element.type !== "radio" || !element.name) return true
    const key = element.name
    const checked = candidates.find(
      (other) => other instanceof HTMLInputElement && other.type === "radio" && other.name === key && other.checked,
    )
    if (checked) return checked === element
    if (seenGroups.has(key)) return false
    seenGroups.add(key)
    return true
  })
  const positive = filtered.filter((element) => tabIndexOf(element) > 0).sort((a, b) => tabIndexOf(a) - tabIndexOf(b))
  return [...positive, ...filtered.filter((element) => tabIndexOf(element) === 0)]
}

export type FocusTarget = HTMLElement | null | undefined | (() => HTMLElement | null | undefined)

const resolveTarget = (target: FocusTarget): HTMLElement | null | undefined =>
  typeof target === "function" ? target() : target

export type FocusScopeOptions = {
  /** Keep Tab and focus inside the container. */
  trap?: boolean
  /** Focus moved here on activate. Default: `[autofocus]`, else the first tabbable, else the container. */
  initialFocus?: FocusTarget | "none"
  /** Restore focus on deactivate. Default true. */
  restoreFocus?: boolean
  /** Where focus goes on deactivate. Default: the element focused before activate. */
  finalFocus?: FocusTarget
}

export interface FocusScope {
  readonly container: HTMLElement
  /** The element that had focus when the scope activated. */
  readonly previous: HTMLElement | null
  focusFirst(): boolean
  focusLast(): boolean
  /** Deactivate, restoring focus when focus is inside the scope or lost. */
  deactivate(options?: { restore?: boolean }): void
}

const scopeStacks = new WeakMap<Document, FocusScope[]>()

/**
 * Activate a focus scope on `container`. Nested scopes stack; only the
 * topmost trapping scope traps.
 */
export const activateFocusScope = (container: HTMLElement, options: FocusScopeOptions = {}): FocusScope => {
  const doc = container.ownerDocument
  const stack = scopeStacks.get(doc) ?? []
  scopeStacks.set(doc, stack)
  const previousActive = activeElementOf(doc)
  const previous = previousActive instanceof HTMLElement && previousActive !== doc.body ? previousActive : null
  const disposers: Dispose[] = []
  let active = true

  const isTop = () => stack[stack.length - 1] === scope

  const focusFirst = () => {
    const first = getTabbables(container)[0]
    return focusElement(first ?? container)
  }
  const focusLast = () => {
    const list = getTabbables(container)
    return focusElement(list[list.length - 1] ?? container)
  }

  const scope: FocusScope = {
    container,
    previous,
    focusFirst,
    focusLast,
    deactivate(deactivateOptions) {
      if (!active) return
      active = false
      for (const dispose of disposers.splice(0)) dispose()
      const index = stack.indexOf(scope)
      if (index >= 0) stack.splice(index, 1)
      const restore = deactivateOptions?.restore ?? options.restoreFocus ?? true
      if (!restore) return
      const current = activeElementOf(doc)
      const focusLost = !current || current === doc.body || !current.isConnected
      if (!focusLost && !contains(container, current)) return
      const target = resolveTarget(options.finalFocus) ?? previous
      if (target?.isConnected) target.focus({ preventScroll: true })
    },
  }
  stack.push(scope)

  if (options.trap) {
    disposers.push(
      listen(container, "keydown", (event: KeyboardEvent) => {
        if (event.key !== "Tab" || event.altKey || event.ctrlKey || event.metaKey || !isTop()) return
        const list = getTabbables(container)
        const first = list[0]
        const last = list[list.length - 1]
        const current = activeElementOf(doc)
        if (!first || !last) {
          event.preventDefault()
          focusElement(container)
          return
        }
        if (event.shiftKey && (current === first || current === container)) {
          event.preventDefault()
          focusElement(last)
        } else if (!event.shiftKey && current === last) {
          event.preventDefault()
          focusElement(first)
        }
      }),
      listen(doc, "focusin", (event: FocusEvent) => {
        if (!isTop() || contains(container, event.target)) return
        // A layer opened above this scope (a menu in a dialog) is not escaping the trap.
        if (event.target instanceof Element && event.target.closest("[data-ui-layer]")) return
        focusFirst()
      }),
    )
  }

  const initial = options.initialFocus
  if (initial !== "none" && !contains(container, activeElementOf(doc))) {
    const explicit = initial === undefined ? container.querySelector<HTMLElement>("[autofocus]") : resolveTarget(initial)
    if (!focusElement(explicit ?? undefined)) focusFirst()
  }
  return scope
}

/**
 * Roving tab index: one item in a composite widget is tabbable; arrow keys
 * move focus between items. The controller owns which item is current; this
 * keeps `tabindex` in sync and moves DOM focus.
 */
export class RovingTabIndex {
  readonly #elements = new Map<string, HTMLElement>()
  readonly #current: Signal<string | null>

  constructor(initial: string | null = null) {
    this.#current = signal(initial)
  }

  get current(): ReadSignal<string | null> {
    return this.#current
  }

  /** Register an item element. Returns the unregister function. */
  register(id: string, element: HTMLElement): Dispose {
    this.#elements.set(id, element)
    element.tabIndex = this.#current.peek() === id || (this.#current.peek() === null && this.#elements.size === 1) ? 0 : -1
    return () => {
      if (this.#elements.get(id) === element) this.#elements.delete(id)
    }
  }

  /** Make `id` the tabbable item, optionally focusing it. */
  setCurrent(id: string | null, focus = false): void {
    this.#current.set(id)
    for (const [key, element] of this.#elements) element.tabIndex = key === id ? 0 : -1
    if (focus && id !== null) focusElement(this.#elements.get(id))
  }

  element(id: string): HTMLElement | undefined {
    return this.#elements.get(id)
  }
}
