/**
 * Bot buttons and agent-card buttons: how each one presents (a link, a
 * button, or disabled with its reason) and which callbacks are in flight.
 * The app performs the action (`ContentHandlers.onAction`); a callback shows
 * a spinner until the promise it returns settles (Mac `MessageActionPerformer`).
 */

import { type ButtonModel, grantReason, previewText, type WebLink } from "@inline/chat-ui"
import type { GrantRequirement } from "@inline/core-protocol"
import { type ReadSignal, signal } from "@inline/reactive"

/**
 * What a button does, in words the bot did not write, for the confirm dialog
 * and the toast (a confirm step's title and text are the bot's, and can say
 * anything). Empty for callbacks, Inline links and compose.
 */
export type ButtonDisclosure = {
  /** Where a link button goes: the web host with port (punycode, as the browser shows it), the mail address, or the phone number. */
  readonly destination?: string
  /** For a copy button: the start of the text, one line, without control or bidi characters, at most `COPY_PREVIEW_GRAPHEMES`. */
  readonly copyPreview?: string
  /** For a copy button: the copied text's length in characters, to say when the preview is partial. */
  readonly copyLength?: number
}

export type ButtonPresentation =
  /** An `openUrl` web link without a confirm step: a real anchor (`target="_blank"`, `rel="noopener noreferrer"`). */
  | { readonly kind: "link"; readonly link: WebLink }
  | { readonly kind: "button"; readonly disclosure?: ButtonDisclosure }
  | { readonly kind: "disabled"; readonly reason: string }

/** Graphemes of copied text shown before the copy is confirmed or in its toast. */
export const COPY_PREVIEW_GRAPHEMES = 80

/** What `ButtonDisclosure` says for a button. The app's confirm dialog and copy toast show it. */
export const buttonDisclosure = (button: ButtonModel): ButtonDisclosure => {
  const behavior = button.behavior
  switch (behavior.kind) {
    case "openUrl": {
      const link = behavior.link
      switch (link.kind) {
        case "web":
          return { destination: link.host }
        case "mail":
          return { destination: link.address }
        case "phone":
          return { destination: link.number }
        case "app":
          return {}
      }
      return {}
    }
    case "copy":
      return {
        copyPreview: previewText(behavior.text, { maxGraphemes: COPY_PREVIEW_GRAPHEMES }),
        copyLength: Array.from(behavior.text).length,
      }
    default:
      return {}
  }
}

export type GrantCheck = (grant: GrantRequirement) => boolean

/**
 * `canUse` is the app's grant check; without one, the button is enabled and
 * the server decides. `names` words the grant reason.
 */
export const presentButton = (
  button: ButtonModel,
  canUse?: GrantCheck,
  names?: { owner?: string; agent?: string },
): ButtonPresentation => {
  const behavior = button.behavior
  if (behavior.kind === "unavailable") return { kind: "disabled", reason: behavior.reason }
  if (button.requiredGrant && canUse && !canUse(button.requiredGrant)) {
    return { kind: "disabled", reason: grantReason(button.requiredGrant, names) }
  }
  if (behavior.kind === "openUrl" && behavior.link.kind === "web" && !button.confirm) {
    return { kind: "link", link: behavior.link }
  }
  const disclosure = buttonDisclosure(button)
  return Object.keys(disclosure).length > 0 ? { kind: "button", disclosure } : { kind: "button" }
}

/**
 * The disclosure as one line for a dialog or toast: "Opens example.com",
 * "Copies “abc”", "Copies “abc…” (519 characters)". Undefined when empty.
 */
export const disclosureText = (disclosure: ButtonDisclosure): string | undefined => {
  if (disclosure.destination) return `Opens ${disclosure.destination}`
  if (disclosure.copyPreview === undefined) return undefined
  const shown = Array.from(disclosure.copyPreview).length
  const partial = disclosure.copyLength !== undefined && disclosure.copyLength > shown
  return `Copies “${disclosure.copyPreview}”${partial ? ` (${disclosure.copyLength} characters)` : ""}`
}

/** Callbacks in flight, per action ID. One per message (button rows and cards share it). */
export class ActionRunner {
  readonly #pending = new Map<string, ReturnType<typeof signal<boolean>>>()
  #disposed = false

  /** True while this action's callback runs. Cached per ID. */
  isPending(actionId: string): ReadSignal<boolean> {
    return this.#flag(actionId)
  }

  /**
   * Run `perform` unless this action is already in flight. Only callbacks
   * (whose result comes back from the bot) are tracked; others run and forget.
   */
  run(button: ButtonModel, perform: () => Promise<void> | void): void {
    if (this.#disposed) return
    const flag = this.#flag(button.actionId)
    if (flag.peek()) return
    let result: Promise<void> | void
    try {
      result = perform()
    } catch {
      return
    }
    if (button.behavior.kind !== "callback" || !result || typeof result.then !== "function") return
    flag.set(true)
    const done = () => {
      if (!this.#disposed) flag.set(false)
    }
    result.then(done, done)
  }

  dispose(): void {
    this.#disposed = true
  }

  #flag(actionId: string): ReturnType<typeof signal<boolean>> {
    let flag = this.#pending.get(actionId)
    if (!flag) {
      flag = signal(false)
      this.#pending.set(actionId, flag)
    }
    return flag
  }
}
