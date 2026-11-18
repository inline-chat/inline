/** Small DOM helpers shared by the foundations and controllers. */

export type Dispose = () => void

export const listen = <K extends keyof HTMLElementEventMap>(
  target: EventTarget,
  type: K | (string & {}),
  handler: (event: HTMLElementEventMap[K]) => void,
  options?: AddEventListenerOptions | boolean,
): Dispose => {
  const listener = handler as EventListener
  target.addEventListener(type, listener, options)
  return () => target.removeEventListener(type, listener, options)
}

/** Run every dispose in reverse order. */
export const disposeAll = (disposers: Dispose[]): void => {
  for (let index = disposers.length - 1; index >= 0; index--) disposers[index]?.()
  disposers.length = 0
}

export const isNode = (value: unknown): value is Node =>
  typeof Node !== "undefined" && value instanceof Node

/** `parent.contains(node)` that tolerates nulls. */
export const contains = (parent: Node | null | undefined, node: unknown): boolean =>
  !!parent && isNode(node) && parent.contains(node)

export type Direction = "ltr" | "rtl"

/** The writing direction in effect for an element. */
export const directionOf = (element: Element | null | undefined): Direction => {
  const holder = element?.closest("[dir]")
  const value = holder?.getAttribute("dir")?.toLowerCase()
  if (value === "rtl") return "rtl"
  if (value === "ltr") return "ltr"
  if (element && typeof getComputedStyle === "function") {
    try {
      if (getComputedStyle(element).direction === "rtl") return "rtl"
    } catch {
      // Detached elements can throw in some engines; assume ltr.
    }
  }
  return "ltr"
}

export const activeElementOf = (doc: Document): Element | null => {
  let active = doc.activeElement
  while (active?.shadowRoot?.activeElement) active = active.shadowRoot.activeElement
  return active
}

export const focusElement = (element: HTMLElement | null | undefined, preventScroll = false): boolean => {
  if (!element || !element.isConnected) return false
  element.focus({ preventScroll })
  return element.ownerDocument.activeElement === element
}

/** Set or remove an attribute; `false`, `null` and `undefined` remove it. */
export const setAttr = (element: Element, name: string, value: string | number | boolean | null | undefined): void => {
  if (value === false || value === null || value === undefined) element.removeAttribute(name)
  else element.setAttribute(name, value === true ? "true" : String(value))
}

/** Like `setAttr`, but writes "false" instead of removing (aria-expanded, aria-selected). */
export const setBoolAttr = (element: Element, name: string, value: boolean): void => {
  element.setAttribute(name, value ? "true" : "false")
}

export type Rect = { x: number; y: number; width: number; height: number }

export const rectOf = (element: Element): Rect => {
  const r = element.getBoundingClientRect()
  return { x: r.left, y: r.top, width: r.width, height: r.height }
}

export const viewportRect = (doc: Document): Rect => {
  const view = doc.defaultView
  const root = doc.documentElement
  return {
    x: 0,
    y: 0,
    width: root.clientWidth || view?.innerWidth || 0,
    height: root.clientHeight || view?.innerHeight || 0,
  }
}

/** Keyboard event fields controllers read; real KeyboardEvents satisfy it. */
export type KeyInput = {
  key: string
  shiftKey?: boolean
  altKey?: boolean
  ctrlKey?: boolean
  metaKey?: boolean
  isComposing?: boolean
  preventDefault?(): void
  stopPropagation?(): void
}

/** A single printable character with no command modifier (typeahead input). */
export const isPrintableKey = (event: KeyInput): boolean =>
  event.key.length === 1 && !event.ctrlKey && !event.metaKey && !event.altKey && !event.isComposing
