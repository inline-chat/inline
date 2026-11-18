/**
 * Everything a message holds beyond its text, for the message row's content
 * slot: the forward line, media, rich blocks, attachments, "Sent via", bot
 * buttons and the reply thread summary. Driven only by props: the row, and
 * an environment shared by the list (`createContentEnv`).
 *
 * Plug it into a row:
 *
 *   const env = createContentEnv({ handlers, names })     // once per list
 *   const context: MessageRowContext = { ..., renderContent: contentRenderer(env) }
 *
 * The slot is drawn above the row's text, so today everything lands there;
 * `sections` picks parts once the row has more slots (README, "Placement").
 */

import * as stylex from "@stylexjs/stylex"
import type { MediaContent, MessageRow } from "@inline/core-protocol"
import type { MediaModel } from "@inline/chat-ui"
import { useModel, useSignal } from "@inline/reactive/react"
import { space } from "@inline/ui/tokens/space.stylex"
import { memo, type ReactNode } from "react"
import { Attachments } from "./AttachmentViews"
import { RichBlocks } from "./BlockViews"
import { ButtonRows } from "./ButtonViews"
import { type ContentModels, hasContent, messageHasContent } from "./content-memo"
import type { ContentEnv } from "./env"
import { DocumentRow, VisualMedia, VoiceRow } from "./MediaViews"
import { contentText } from "./RichText"
import { RowContent } from "./row-content"
import type { MediaOwner } from "./sources"
import { ForwardLine, RepliesSummary, ViaLine } from "./ServiceViews"

export type ContentSection = "forward" | "media" | "blocks" | "attachments" | "via" | "buttons" | "replies"

export const allSections: readonly ContentSection[] = ["forward", "media", "blocks", "attachments", "via", "buttons", "replies"]

export type MessageContentProps = {
  readonly message: MessageRow
  /** Shared by every row of a list. Keep its identity. */
  readonly env: ContentEnv
  /** Parts to draw, in this fixed order; default all. Keep the array's identity. */
  readonly sections?: readonly ContentSection[]
  /**
   * Find-in-chat ranges into the message text (UTF-16 `[start, end)`), drawn
   * in blocks whose text comes from the message text. Keep the array's
   * identity while the match does not move.
   */
  readonly highlightRanges?: readonly (readonly [start: number, end: number])[]
}

/** A message's content. Memoized; renders again when the row, env or sections change identity. */
export const MessageContent = memo(function MessageContent(props: MessageContentProps): ReactNode {
  const { message, env } = props
  const tone = message.out ? "outgoing" : "incoming"
  const row = useModel(() => new RowContent(env, message.id, tone), [env, message.id, tone])
  const disclosures = useSignal(row.disclosures.open)
  const models = row.memo.read(message, env, disclosures, props.highlightRanges)
  if (!hasContent(models)) return null
  const sections = props.sections ?? allSections
  const owner = models.media ? row.mediaOwner(message) : undefined
  return (
    <div data-message-content={message.id} {...stylex.props(styles.root, contentText.body)}>
      {sections.map((section) => (
        <Section key={section} section={section} models={models} ctx={row} owner={owner} />
      ))}
    </div>
  )
})

function Section(props: { section: ContentSection; models: ContentModels; ctx: RowContent; owner: MediaOwner | undefined }): ReactNode {
  const { models, ctx } = props
  switch (props.section) {
    case "forward":
      return models.forward ? <ForwardLine model={models.forward} ctx={ctx} /> : null
    case "media":
      return models.media ? <MessageMedia media={models.media} raw={models.rawMedia} ctx={ctx} owner={props.owner} /> : null
    case "blocks":
      return models.blocks ? (
        <div data-blocks="" {...stylex.props(styles.blocks)}>
          <RichBlocks blocks={models.blocks.blocks} ctx={ctx} />
        </div>
      ) : null
    case "attachments":
      return <Attachments models={models.attachments} ctx={ctx} />
    case "via":
      return models.via ? <ViaLine model={models.via} ctx={ctx} /> : null
    case "buttons":
      return <ButtonRows model={models.buttons} ctx={ctx} />
    case "replies":
      return models.replies ? <RepliesSummary model={models.replies} ctx={ctx} /> : null
  }
}

/**
 * The message's photo, video, GIF, sticker, document or voice note. A nudge is
 * the row's text. `owner` (`RowContent.mediaOwner`) lets the media layer ask
 * the core for this message's bytes and draws a send's upload.
 */
export function MessageMedia(props: {
  media: MediaModel
  raw: MediaContent | undefined
  ctx: RowContent
  owner?: MediaOwner | undefined
}): ReactNode {
  const { media, raw, ctx, owner } = props
  switch (media.kind) {
    case "photo":
    case "video":
    case "gif":
      return <VisualMedia media={media} ctx={ctx} owner={owner} />
    case "document":
      return raw ? <DocumentRow model={media} raw={raw} ctx={ctx} owner={owner} /> : null
    case "voice":
      return raw ? <VoiceRow model={media} raw={raw} ctx={ctx} owner={owner} /> : null
    case "nudge":
      return null
  }
}

/**
 * A `renderContent` for `MessageRowContext`: the content, or null when the
 * message has none, so text-only rows keep their plain layout. Create it once
 * per environment (and sections) and keep it on the context.
 */
export const contentRenderer =
  (env: ContentEnv, sections?: readonly ContentSection[]) =>
  (message: MessageRow): ReactNode =>
    messageHasContent(message) ? (
      <MessageContent message={message} env={env} {...(sections ? { sections } : {})} />
    ) : null

const styles = stylex.create({
  root: { display: "flex", flexDirection: "column", alignItems: "flex-start", gap: space.sm, minInlineSize: 0, maxInlineSize: "100%" },
  blocks: { alignSelf: "stretch", minInlineSize: 0 },
})
