/**
 * Test helpers for controllers that need a DOM (happy-dom). Fixtures are
 * built with `h`, never from HTML strings.
 */

type Attrs = Record<string, string | number | boolean | undefined>

/** Create an element. `true` sets an empty attribute; `false` and undefined skip it. */
export const h = (tag: string, attrs: Attrs = {}, ...children: Array<Node | string>): HTMLElement => {
  const element = document.createElement(tag)
  for (const [name, value] of Object.entries(attrs)) {
    if (value === false || value === undefined) continue
    element.setAttribute(name, value === true ? "" : String(value))
  }
  element.append(...children)
  return element
}

/** Append to the body and return. */
export const mount = <T extends HTMLElement>(element: T): T => {
  document.body.append(element)
  return element
}

export const keydown = (target: EventTarget, key: string, init: KeyboardEventInit = {}): KeyboardEvent => {
  const event = new KeyboardEvent("keydown", { key, bubbles: true, cancelable: true, composed: true, ...init })
  target.dispatchEvent(event)
  return event
}

/** Press a key on whatever has focus. */
export const press = (key: string, init: KeyboardEventInit = {}): KeyboardEvent =>
  keydown(document.activeElement ?? document.body, key, init)

export const pointer = (
  target: EventTarget,
  type: "pointerdown" | "pointerup" | "pointermove" | "pointerenter" | "pointerleave",
  init: PointerEventInit = {},
): PointerEvent => {
  const event = new PointerEvent(type, {
    bubbles: type !== "pointerenter" && type !== "pointerleave",
    cancelable: true,
    composed: true,
    pointerType: "mouse",
    button: 0,
    ...init,
  })
  target.dispatchEvent(event)
  return event
}

export const click = (target: EventTarget, init: MouseEventInit = {}): MouseEvent => {
  const event = new MouseEvent("click", { bubbles: true, cancelable: true, composed: true, detail: 1, ...init })
  target.dispatchEvent(event)
  return event
}

/** Give an element a fixed layout box (happy-dom does no layout). */
export const setRect = (element: Element, x: number, y: number, width: number, height: number): void => {
  element.getBoundingClientRect = () => DOMRect.fromRect({ x, y, width, height })
}

export const activeId = (): string | undefined => (document.activeElement as HTMLElement | null)?.id || undefined
