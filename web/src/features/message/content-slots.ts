/**
 * Where a message's content goes in its row, decided from the row alone.
 * Mac layout (`MessageView`, `MessageSizeCalculator`):
 *
 * - `above`, inside the bubble above the text: the forward line, media
 *   (photo, video, GIF, sticker, document, voice) and rich blocks.
 * - `below`, inside the bubble below the text: link previews and external
 *   task cards, and "Sent via".
 * - `outside`, under the bubble: bot button rows and the reply thread summary.
 *
 * Rich blocks are a projection of `text` (`MessageRow.blocks`), so content
 * with blocks replaces the row's own text. Stickers, and PNG photos without a
 * caption, are drawn without the bubble (chat-ui's `mediaModel().noBubble`).
 *
 * The row never imports the content views: a caller hands it a
 * `MessageRowContent` (a plan function and a slot renderer) through
 * `MessageRowContext.content`. `slottedContent` builds one from any renderer.
 */

import type { MessageRow } from "@inline/core-protocol"
import { mediaModel, repliesSummaryModel } from "@inline/chat-ui"
import type { FindRanges } from "./find"

export type ContentSlot = "above" | "below" | "outside"

export const CONTENT_SLOTS: readonly ContentSlot[] = ["above", "below", "outside"]

/**
 * The content sections each slot draws, in order, by the names
 * `MessageContent` uses for its `sections` prop. Constant arrays: pass them
 * as they are so their identity stays stable.
 */
export const CONTENT_SLOT_SECTIONS = {
  above: ["forward", "media", "blocks"],
  below: ["attachments", "via"],
  outside: ["buttons", "replies"],
} as const satisfies Record<ContentSlot, readonly string[]>

export type ContentPlan = {
  readonly above: boolean
  readonly below: boolean
  readonly outside: boolean
  /** The content draws the message text (rich blocks); the row must not draw it again. */
  readonly replacesText: boolean
  /** Draw the message without the bubble's background and tail. */
  readonly noBubble: boolean
}

/** What the row hands a slot besides the message. */
export type ContentRenderOptions = {
  /**
   * Find-in-chat ranges (UTF-16 `[start, end)` into `message.text`). Passed
   * only to the `above` slot and only when the content replaces the text
   * (rich blocks); otherwise the row's own text shows them. Stable identity
   * while unchanged.
   */
  readonly highlightRanges?: FindRanges
}

/** What a row needs from the content layer. Keep the object's identity stable. */
export type MessageRowContentSource<Node> = {
  /** Pure and cheap; null when the message has no content. Same input, same (interned) result. */
  readonly plan: (message: MessageRow) => ContentPlan | null
  /** The content for one slot. Called only for slots the plan marks. */
  readonly render: (message: MessageRow, slot: ContentSlot, options: ContentRenderOptions) => Node
}

const plans = new Map<number, ContentPlan>()

/** One object per combination, so `===` says whether a plan changed. */
const intern = (plan: ContentPlan): ContentPlan | null => {
  if (!plan.above && !plan.below && !plan.outside) return null
  const key =
    (plan.above ? 1 : 0) | (plan.below ? 2 : 0) | (plan.outside ? 4 : 0) | (plan.replacesText ? 8 : 0) | (plan.noBubble ? 16 : 0)
  let interned = plans.get(key)
  if (!interned) {
    interned = plan
    plans.set(key, interned)
  }
  return interned
}

const hasReplies = (replies: MessageRow["replies"]): boolean => repliesSummaryModel(replies) !== undefined

/** Whether the media is drawn without a bubble; mirrors chat-ui's model (stickers, PNG photos without a caption). */
const mediaWithoutBubble = (row: MessageRow): boolean => {
  const media = row.media
  if (!media || (media.kind !== "photo" && media.kind !== "video")) return false
  const model = mediaModel(row)
  return model !== undefined && "noBubble" in model && model.noBubble
}

const cache = new WeakMap<MessageRow, ContentPlan | null>()

/**
 * The plan for a row, from its fields. Service messages have none (they are
 * service rows, not message rows). Cached per row object.
 */
export const planContent = (row: MessageRow): ContentPlan | null => {
  const cached = cache.get(row)
  if (cached !== undefined) return cached
  let plan: ContentPlan | null = null
  if (row.service === undefined) {
    const blocks = (row.blocks?.length ?? 0) > 0
    const media = row.media !== undefined && row.media.kind !== "nudge"
    plan = intern({
      above: row.forward !== undefined || media || blocks,
      below: (row.attachments?.some((attachment) => attachment.kind !== "unknown") ?? false) || row.via !== undefined,
      outside: (row.actions?.some((buttons) => buttons.length > 0) ?? false) || hasReplies(row.replies),
      replacesText: blocks,
      noBubble: mediaWithoutBubble(row) && !blocks && (row.attachments?.length ?? 0) === 0,
    })
  }
  cache.set(row, plan)
  return plan
}

/**
 * A content source from a slot renderer, with `planContent` as its plan
 * (or another plan function). Create it once per renderer.
 */
export const slottedContent = <Node>(
  render: (message: MessageRow, slot: ContentSlot, options: ContentRenderOptions) => Node,
  plan: (message: MessageRow) => ContentPlan | null = planContent,
): MessageRowContentSource<Node> => ({ plan, render })
