/**
 * The render models for one message's content, kept identity-stable across
 * updates. Rows arrive as fresh copies (a reaction, an edit, a streaming
 * append): every model is rebuilt with `chat-ui` and passed through
 * `reuseTree`, so an unchanged part keeps its object and its memoized view
 * renders nothing. The block tree goes through `updateBlockTree`, so a
 * streaming append changes one block.
 *
 * Also the per-message disclosure state: which disclosures the user opened or
 * closed, by block key, so a toggle survives updates and decides which agent
 * cards claim their buttons.
 */

import {
  type AttachmentModel,
  attachmentModels,
  type BlockTree,
  type BlockTreeOptions,
  buttonRowsModel,
  type ButtonRowsModel,
  type ForwardHeaderModel,
  forwardHeaderModel,
  type MediaModel,
  mediaModel,
  repliesSummaryModel,
  type RepliesSummaryModel,
  reuseTree,
  updateBlockTree,
  type ViaModel,
  viaModel,
} from "@inline/chat-ui"
import type { MediaContent, MessageRow } from "@inline/core-protocol"
import { type ReadSignal, signal } from "@inline/reactive"
import type { ContentEnv } from "./env"

export type ContentModels = {
  readonly forward: ForwardHeaderModel | undefined
  readonly media: MediaModel | undefined
  /** The row's media as data (for downloads and sources), identity-stable like the models. */
  readonly rawMedia: MediaContent | undefined
  /** Undefined when the message renders as its flat text. */
  readonly blocks: BlockTree | undefined
  readonly attachments: readonly AttachmentModel[]
  /** Without the IDs the block tree's cards draw. */
  readonly buttons: ButtonRowsModel
  readonly via: ViaModel | undefined
  readonly replies: RepliesSummaryModel | undefined
}

type MemoEnv = Pick<ContentEnv, "layout" | "names" | "me" | "text" | "links" | "now">

const emptyDisclosures: ReadonlyMap<string, boolean> = new Map()

export class ContentMemo {
  #row: MessageRow | undefined
  #env: MemoEnv | undefined
  #disclosures: ReadonlyMap<string, boolean> | undefined
  #highlights: BlockTreeOptions["highlightRanges"]
  #models: ContentModels | undefined

  /**
   * `highlightRanges` are find-in-chat ranges into the message text, for a
   * message whose blocks replace its text. Keep the array's identity while
   * the match does not move.
   */
  read(
    row: MessageRow,
    env: MemoEnv,
    disclosures: ReadonlyMap<string, boolean> = emptyDisclosures,
    highlightRanges?: BlockTreeOptions["highlightRanges"],
  ): ContentModels {
    const prev = this.#models
    if (
      prev &&
      row === this.#row &&
      env === this.#env &&
      disclosures === this.#disclosures &&
      highlightRanges === this.#highlights
    ) {
      return prev
    }
    const layout = env.layout
    const blockOptions: BlockTreeOptions = {
      ...(env.text ? { text: env.text } : {}),
      ...(env.links ? { links: env.links } : {}),
      ...(layout.availableWidth !== undefined ? { availableWidth: layout.availableWidth } : {}),
      ...(env.now ? { now: env.now() } : {}),
      openDisclosures: disclosures,
      ...(highlightRanges && highlightRanges.length > 0 ? { highlightRanges } : {}),
    }
    // `updateBlockTree` returns its previous tree for the same row whatever
    // the options, so a changed option (a disclosure toggle) rebuilds; the
    // `reuseTree` below still keeps every unchanged node.
    const optionsChanged = env !== this.#env || disclosures !== this.#disclosures
    const blocks = row.blocks?.length
      ? updateBlockTree(optionsChanged ? undefined : prev?.blocks, row, blockOptions)
      : undefined
    const claimed = blocks && blocks.claimedActionIds.length > 0 ? new Set(blocks.claimedActionIds) : undefined
    const sender = env.names.user?.(row.fromId)?.name
    const next: ContentModels = {
      forward: row.forward
        ? forwardHeaderModel(row.forward, {
            ...(env.names.forwardTitle ? { title: env.names.forwardTitle(row.forward) } : {}),
            ...(env.me ? { me: env.me } : {}),
          })
        : undefined,
      media: mediaModel(row, {
        ...(layout.availableWidth !== undefined ? { availableWidth: layout.availableWidth } : {}),
        ...(layout.style ? { style: layout.style } : {}),
        ...(layout.locale ? { locale: layout.locale } : {}),
      }),
      rawMedia: row.media,
      blocks,
      attachments: attachmentModels(row, layout.style ? { style: layout.style } : {}),
      buttons: buttonRowsModel(row.actions, claimed, env.links),
      via: row.via
        ? viaModel(row.via, {
            ...(sender ? { sender } : {}),
            ...(row.via.kind === "bot" && env.names.botName
              ? { botName: env.names.botName(row.via.botUserId) ?? "" }
              : {}),
          })
        : undefined,
      replies: repliesSummaryModel(row.replies, layout.locale),
    }
    const models = prev ? reuseTree(prev, next) : next
    this.#row = row
    this.#env = env
    this.#disclosures = disclosures
    this.#highlights = highlightRanges
    this.#models = models
    return models
  }
}

/** Disclosures the user toggled in one message, by block key. */
export class DisclosureState {
  readonly #open = signal<ReadonlyMap<string, boolean>>(emptyDisclosures)

  get open(): ReadSignal<ReadonlyMap<string, boolean>> {
    return this.#open
  }

  /** Whether a disclosure is open: the user's toggle, else the sender's default. */
  isOpen(key: string, initiallyOpen: boolean): boolean {
    return this.#open.peek().get(key) ?? initiallyOpen
  }

  set(key: string, open: boolean): void {
    const current = this.#open.peek()
    if (current.get(key) === open) return
    const next = new Map(current)
    next.set(key, open)
    this.#open.set(next)
  }
}

/**
 * Whether a message has anything for `MessageContent` to draw, from the row
 * alone (no models built), so a row's `renderContent` can return null.
 */
export const messageHasContent = (row: MessageRow): boolean =>
  row.service === undefined &&
  (row.forward !== undefined ||
    (row.media !== undefined && row.media.kind !== "nudge") ||
    (row.blocks?.length ?? 0) > 0 ||
    (row.attachments?.some((attachment) => attachment.kind !== "unknown") ?? false) ||
    (row.actions?.some((buttons) => buttons.length > 0) ?? false) ||
    row.via !== undefined ||
    (row.replies !== undefined && repliesSummaryModel(row.replies) !== undefined))

/** Whether built models have anything to draw. */
export const hasContent = (models: ContentModels): boolean =>
  models.forward !== undefined ||
  (models.media !== undefined && models.media.kind !== "nudge") ||
  models.blocks !== undefined ||
  models.attachments.length > 0 ||
  models.buttons.rows.length > 0 ||
  models.via !== undefined ||
  models.replies !== undefined
