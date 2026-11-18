/**
 * Which media boxes of one timeline are visible, and which are near (within
 * about one viewport above or below). Framework-free; the chat pane hands it
 * the timeline's scroll container with `useElement`, and the media sources
 * hand it each media box they hold.
 *
 * Two observers rooted at the container, shared by every box: one with no
 * margin (visible), one with a margin of one container height above and
 * below (nearby). One observer cannot do both: a box moving from "near" to
 * "visible" stays fully inside the expanded root, so an observer with the
 * margin reports nothing for that move.
 *
 * The controller only tracks; it calls `onChange` when either set changed,
 * and its owner (`CoreMediaSources`) turns the sets into subscriptions and
 * `mediaHints`, once per frame.
 */

export type ObserverEntry = { readonly target: Element; readonly isIntersecting: boolean }

export type ObserverLike = {
  observe(element: Element): void
  unobserve(element: Element): void
  disconnect(): void
}

export type ObserverInit = { readonly root: Element; readonly rootMargin: string }

export type CreateObserver = (callback: (entries: readonly ObserverEntry[]) => void, init: ObserverInit) => ObserverLike

export const browserObserver: CreateObserver = (callback, init) =>
  new IntersectionObserver((entries) => callback(entries), { root: init.root, rootMargin: init.rootMargin, threshold: 0 })

/** One viewport above and below: rows the reader reaches with one page of scrolling. */
export const NEARBY_MARGIN = "100% 0px"

export type MediaVisibilityOptions<T> = {
  /** Either set changed. Called synchronously from the observers' callbacks; coalesce it. */
  readonly onChange: (visibility: MediaVisibility<T>) => void
  readonly createObserver?: CreateObserver
  readonly nearbyMargin?: string
}

export class MediaVisibility<T> {
  readonly #onChange: (visibility: MediaVisibility<T>) => void
  readonly #createObserver: CreateObserver
  readonly #margin: string
  /** What each observed box shows. */
  readonly #targets = new Map<Element, Set<T>>()
  readonly #visible = new Set<Element>()
  readonly #nearby = new Set<Element>()
  #container: Element | undefined
  #visibleObserver: ObserverLike | undefined
  #nearbyObserver: ObserverLike | undefined
  #disposed = false

  constructor(options: MediaVisibilityOptions<T>) {
    this.#onChange = options.onChange
    this.#createObserver = options.createObserver ?? browserObserver
    this.#margin = options.nearbyMargin ?? NEARBY_MARGIN
  }

  /** The timeline's scroll container. For `useElement`. */
  readonly attach = (container: Element): (() => void) => {
    if (this.#disposed) return () => {}
    this.#detach()
    this.#container = container
    this.#visibleObserver = this.#createObserver((entries) => this.#update(this.#visible, entries), {
      root: container,
      rootMargin: "0px",
    })
    this.#nearbyObserver = this.#createObserver((entries) => this.#update(this.#nearby, entries), {
      root: container,
      rootMargin: this.#margin,
    })
    for (const element of this.#targets.keys()) {
      if (!container.contains(element)) continue
      this.#visibleObserver.observe(element)
      this.#nearbyObserver.observe(element)
    }
    return () => {
      if (this.#container === container) this.#detach()
    }
  }

  /** Whether a box is inside this timeline (attached and contained). */
  covers(element: Element): boolean {
    return this.#container !== undefined && this.#container !== element && this.#container.contains(element)
  }

  /** Watch a box for a target. A box can show several targets (a GIF's thumbnail and video). */
  observe(element: Element, target: T): void {
    if (this.#disposed) return
    let targets = this.#targets.get(element)
    if (!targets) {
      targets = new Set()
      this.#targets.set(element, targets)
      if (this.covers(element)) {
        this.#visibleObserver?.observe(element)
        this.#nearbyObserver?.observe(element)
      }
    }
    targets.add(target)
  }

  unobserve(element: Element, target: T): void {
    const targets = this.#targets.get(element)
    if (!targets?.delete(target) || targets.size > 0) return
    this.#targets.delete(element)
    this.#visibleObserver?.unobserve(element)
    this.#nearbyObserver?.unobserve(element)
    const wasVisible = this.#visible.delete(element)
    const wasNearby = this.#nearby.delete(element)
    if (wasVisible || wasNearby) this.#onChange(this)
  }

  /** Targets shown by a visible box. */
  visible(): Set<T> {
    return this.#collect(this.#visible)
  }

  /** Targets shown by a box within the nearby margin, visible ones included. */
  nearby(): Set<T> {
    return this.#collect(this.#nearby)
  }

  get size(): number {
    return this.#targets.size
  }

  dispose(): void {
    if (this.#disposed) return
    this.#disposed = true
    this.#detach()
    this.#targets.clear()
  }

  #collect(elements: ReadonlySet<Element>): Set<T> {
    const result = new Set<T>()
    for (const element of elements) for (const target of this.#targets.get(element) ?? []) result.add(target)
    return result
  }

  #update(set: Set<Element>, entries: readonly ObserverEntry[]) {
    let changed = false
    for (const entry of entries) {
      if (!this.#targets.has(entry.target)) continue
      if (entry.isIntersecting) {
        if (!set.has(entry.target)) {
          set.add(entry.target)
          changed = true
        }
      } else if (set.delete(entry.target)) {
        changed = true
      }
    }
    if (changed) this.#onChange(this)
  }

  #detach() {
    this.#visibleObserver?.disconnect()
    this.#nearbyObserver?.disconnect()
    this.#visibleObserver = undefined
    this.#nearbyObserver = undefined
    this.#container = undefined
    const changed = this.#visible.size > 0 || this.#nearby.size > 0
    this.#visible.clear()
    this.#nearby.clear()
    if (changed && !this.#disposed) this.#onChange(this)
  }
}
