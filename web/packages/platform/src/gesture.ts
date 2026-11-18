/**
 * Proof that a call comes from a user gesture. Browsers show a permission
 * prompt (and some file pickers) only during transient user activation, and
 * penalize sites that prompt without one. Requiring a token that only
 * `userGesture(event)` can mint makes the call site visibly a click or key
 * handler.
 */

declare const gestureBrand: unique symbol

export interface UserGesture {
  readonly [gestureBrand]: true
  readonly eventType: string
}

/** Event types that grant transient activation (HTML "activation triggering input event"). */
const ACTIVATING_EVENTS: ReadonlySet<string> = new Set([
  "click",
  "keydown",
  "keyup",
  "mousedown",
  "mouseup",
  "pointerdown",
  "pointerup",
  "touchend",
  "submit",
])

const issued = new WeakSet<object>()

export type GestureEventLike = { readonly isTrusted: boolean; readonly type: string }

/** A token for a trusted click, key or pointer event; null for anything else. */
export const userGesture = (event: GestureEventLike): UserGesture | null => {
  if (!event.isTrusted || !ACTIVATING_EVENTS.has(event.type)) return null
  const token = { eventType: event.type } as unknown as UserGesture
  issued.add(token)
  return token
}

/** True only for a token minted by `userGesture`. */
export const isUserGesture = (value: unknown): value is UserGesture =>
  typeof value === "object" && value !== null && issued.has(value)
