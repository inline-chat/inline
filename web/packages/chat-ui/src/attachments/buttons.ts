/**
 * Bot buttons (`MessageActionRowsView.swift`, `MessageActionPresentation.swift`,
 * `MessageActionPerformer.swift`).
 *
 * Each button resolves to a behavior the app performs:
 * - `callback`: invoke the action by ID; show a spinner until the bot answers.
 * - `copy`: copy the text, toast "Copied".
 * - `openLink`: an Inline chat or message.
 * - `openUrl`: a link that passed `safeLink`. Web, mail and phone links open
 *   directly; app links are handed to the app's router. The Mac also opens
 *   other app schemes (`codex://`) after confirming the destination; the web
 *   refuses every scheme `safeLink` refuses, so those buttons are unavailable.
 * - `compose`: put the text (trimmed, 1 to 4000 characters) in the composer.
 * - `unavailable`: the action is malformed or unknown; clicking toasts
 *   "This action isn’t available".
 *
 * Buttons that a rich block draws (agent cards) are left out of the rows:
 * pass their IDs as `claimed`.
 */

import type { GrantRequirement, MessageActionButton, MessageActionRows, PeerRef } from "@inline/core-protocol"
import type { MessageID } from "@inline/ids"
import { safeLink, type SafeLink, type SafeLinkOptions } from "../links"

export type ButtonBehavior =
  | { readonly kind: "callback" }
  | { readonly kind: "copy"; readonly text: string }
  | { readonly kind: "openUrl"; readonly link: SafeLink }
  | { readonly kind: "openLink"; readonly peer: PeerRef; readonly messageId: MessageID | undefined }
  | { readonly kind: "compose"; readonly text: string }
  | { readonly kind: "unavailable"; readonly reason: string }

export type ButtonModel = {
  readonly key: string
  readonly actionId: string
  readonly label: string
  readonly style: MessageActionButton["style"]
  readonly behavior: ButtonBehavior
  /** Ask first: title, optional text, the confirm label and "Cancel". */
  readonly confirm: { readonly title: string; readonly text: string | undefined; readonly confirmLabel: string } | undefined
  /** The viewer needs this grant; the app decides whether they have it (`grantReason` for the wording). */
  readonly requiredGrant: GrantRequirement | undefined
}

export type ButtonRowsModel = {
  readonly rows: readonly (readonly ButtonModel[])[]
  /** Row height and spacing between rows and buttons; buttons split a row's width equally. */
  readonly rowHeight: number
  readonly spacing: number
}

export const unavailableActionText = "This action isn’t available"
export const maxComposeLength = 4000

const behaviorOf = (button: MessageActionButton, links: SafeLinkOptions | undefined): ButtonBehavior => {
  const action = button.action
  switch (action.kind) {
    case "callback":
      return { kind: "callback" }
    case "copyText":
      return { kind: "copy", text: action.text }
    case "openUrl": {
      const link = safeLink(action.url, links)
      return link ? { kind: "openUrl", link } : { kind: "unavailable", reason: unavailableActionText }
    }
    case "openLink":
      return { kind: "openLink", peer: action.peer, messageId: action.messageId }
    case "compose": {
      const text = action.text.trim()
      return text.length > 0 && text.length <= maxComposeLength
        ? { kind: "compose", text }
        : { kind: "unavailable", reason: unavailableActionText }
    }
    case "unknown":
      return { kind: "unavailable", reason: unavailableActionText }
  }
}

/** One button's model. */
export const buttonModel = (button: MessageActionButton, links?: SafeLinkOptions): ButtonModel => ({
  key: `action:${button.actionId}`,
  actionId: button.actionId,
  label: button.text,
  style: button.style,
  behavior: behaviorOf(button, links),
  confirm: button.confirm
    ? {
        title: button.confirm.title.trim().length > 0 ? button.confirm.title : button.text,
        text: button.confirm.text,
        confirmLabel: button.confirm.confirmText ?? button.text,
      }
    : undefined,
  requiredGrant: button.requiredGrant,
})

/** The message's button rows, without the IDs a rich block claimed. Empty rows are dropped. */
export const buttonRowsModel = (
  actions: MessageActionRows | undefined,
  claimed: ReadonlySet<string> = new Set(),
  links?: SafeLinkOptions,
): ButtonRowsModel => ({
  rows: (actions ?? [])
    .map((row) => row.filter((button) => !claimed.has(button.actionId)).map((button) => buttonModel(button, links)))
    .filter((row) => row.length > 0),
  rowHeight: 28,
  spacing: 4,
})

/** Buttons by ID for a rich block: in order, deduplicated, known, with a label. */
export const buttonsById = (
  actions: MessageActionRows | undefined,
  ids: readonly string[],
  links?: SafeLinkOptions,
): ButtonModel[] => {
  const byId = new Map<string, MessageActionButton>()
  for (const row of actions ?? []) for (const button of row) if (!byId.has(button.actionId)) byId.set(button.actionId, button)
  const seen = new Set<string>()
  const result: ButtonModel[] = []
  for (const id of ids) {
    if (seen.has(id)) continue
    seen.add(id)
    const button = byId.get(id)
    if (button && button.text.trim().length > 0) result.push(buttonModel(button, links))
  }
  return result
}

/**
 * Why a viewer without the grant cannot use a button, in the Mac's words.
 * `owner` defaults to "the agent’s owner", `agent` to "this agent".
 */
export const grantReason = (requirement: GrantRequirement, names: { owner?: string; agent?: string } = {}): string => {
  const owner = names.owner ?? "the agent’s owner"
  const agent = names.agent ?? "this agent"
  switch (requirement) {
    case "approve":
      return `Only ${owner} can approve`
    case "access":
      return `Only people with access to ${agent} can answer`
    case "invoke":
      return `Ask ${owner} for access to ${agent}`
    case "steer":
      return `Only ${owner} and people they allow can steer ${agent}`
    case "configure":
    case "owner":
      return `Only ${owner} can change this`
    case "unknown":
      return "You can’t use this"
  }
}
