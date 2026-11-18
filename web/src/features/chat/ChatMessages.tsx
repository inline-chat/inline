/**
 * How the chat pane renders timeline items with the message views
 * (`web/src/features/message/`): a message row with its sender and its
 * content slots, a service row, the day separator and the unread line.
 * `createRenderItem` returns a function that is stable for one chat (the
 * timeline view re-renders every row when it changes), with the row context
 * (and its content source) created once alongside it.
 *
 * Content (`chat-content.ts`) is a chunk of its own, loaded after the
 * shell's first paint. Each slot reads the chunk itself, so its arrival
 * renders the slots and not the rows; until it is there a photo or video
 * slot keeps its final box, and other slots stay empty.
 */

import { createTimeFormatter, mediaModel, type TimeFormatter } from "@inline/chat-ui"
import type { MessageItem, TimelineItem } from "@inline/timeline"
import { useElement, useSignal } from "@inline/reactive/react"
import type { Destination } from "@inline/view"
import type { ViewStore } from "@inline/reactive"
import type { MessageRow, MessageRowId, ReactionSummary, UserRow } from "@inline/core-protocol"
import type { MessageID } from "@inline/ids"
import { color } from "@inline/ui/tokens/color.stylex"
import * as stylex from "@stylexjs/stylex"
import { memo, type ReactNode } from "react"
import {
  createMessageTimes,
  DaySeparatorRow,
  MessageRowView,
  presentSender,
  slottedContent,
  UnreadLineRow,
  type ContentRenderOptions,
  type ContentSlot,
  type FindRanges,
  type MessageActionsController,
  type MessageRowContext,
} from "../message"
import type { ChatContent } from "./chat-content"

const formatters = new Map<string, TimeFormatter>()

/** One time formatter per time zone for the page. */
const formatterFor = (timeZone: string): TimeFormatter => {
  let formatter = formatters.get(timeZone)
  if (!formatter) {
    formatter = createTimeFormatter({ timeZone })
    formatters.set(timeZone, formatter)
  }
  return formatter
}

export type RenderItemOptions = {
  readonly store: ViewStore
  readonly timeZone: string
  readonly isDM: boolean
  /** An in-app link in a message: where it goes, or undefined to let the browser follow it. */
  readonly parseAppLink: (href: string) => Destination | undefined
  readonly openDestination: (destination: Destination) => void
  /** The pane's message content (media, blocks, buttons, service rows). Without it rows draw text only. */
  readonly content?: ChatContent
  /** The reply line was activated: go to the replied message. */
  readonly onReplyClick?: (rowId: MessageRowId, messageId: MessageID) => void
  /** A reaction chip: add or remove the viewer's reaction. */
  readonly onReactionClick?: (rowId: MessageRowId, reaction: ReactionSummary) => void
  /** Hover quick actions and the context menu. */
  readonly actions?: MessageActionsController
  /** Find in chat: the active match's ranges per row (`FindHighlights.rangesFor`). */
  readonly highlightRangesFor?: MessageRowContext["highlightRangesFor"]
  /** The emoji table once loaded: reaction chips are named by it ("thumbs up, 3, including you"). */
  readonly emojiEngine?: MessageRowContext["emojiEngine"]
  /** The viewer, so a chip's tooltip says "You". */
  readonly viewerId?: string
}

export const createRenderItem = (options: RenderItemOptions): ((item: TimelineItem) => ReactNode) => {
  const formatter = formatterFor(options.timeZone)
  const chatContent = options.content
  const context: MessageRowContext = {
    times: createMessageTimes(formatter),
    isDM: options.isDM,
    handlers: {
      onAppLink: (link, event) => {
        const destination = options.parseAppLink(link.href)
        if (!destination) return
        event.preventDefault()
        options.openDestination(destination)
      },
      ...(options.onReplyClick ? { onReplyClick: options.onReplyClick } : {}),
      ...(options.onReactionClick ? { onReactionClick: options.onReactionClick } : {}),
    },
    ...(options.actions ? { actions: options.actions } : {}),
    ...(options.highlightRangesFor ? { highlightRangesFor: options.highlightRangesFor } : {}),
    ...(options.emojiEngine ? { emojiEngine: options.emojiEngine } : {}),
    ...(options.viewerId !== undefined ? { viewerId: options.viewerId } : {}),
    ...(chatContent
      ? {
          content: slottedContent((message: MessageRow, slot: ContentSlot, slotOptions: ContentRenderOptions) => (
            <ContentSlotItem
              message={message}
              slot={slot}
              content={chatContent}
              {...(slotOptions.highlightRanges ? { highlightRanges: slotOptions.highlightRanges } : {})}
            />
          )),
        }
      : {}),
  }
  const dayLabels = new Map<string, string>()
  return (item) => {
    switch (item.kind) {
      case "message":
        return <ChatMessageItem item={item} context={context} store={options.store} content={chatContent} />
      case "day": {
        let label = dayLabels.get(item.dayKey)
        if (label === undefined) {
          label = formatter.dayLabel(item.date).text
          dayLabels.set(item.dayKey, label)
        }
        return <DaySeparatorRow label={label} />
      }
      case "unread":
        return <UnreadLineRow />
    }
  }
}

/** A message with its sender, read from the sender's own user row; a service message once content is there. */
const ChatMessageItem = memo(function ChatMessageItem(props: {
  item: MessageItem
  context: MessageRowContext
  store: ViewStore
  content: ChatContent | undefined
}) {
  const message = props.item.row
  const user = useSignal(props.store.row("user", message.fromId)) as UserRow | undefined
  if (message.service !== undefined && props.content) return <ServiceItem {...props} sender={user} />
  return <MessageItemRow {...props} sender={user} />
})

function MessageItemRow(props: { item: MessageItem; context: MessageRowContext; sender: UserRow | undefined }) {
  return (
    <MessageRowView
      message={props.item.row}
      firstInGroup={props.item.firstInGroup}
      lastInGroup={props.item.lastInGroup}
      context={props.context}
      {...(props.sender ? { sender: presentSender(props.sender) } : {})}
    />
  )
}

/** A service row draws as a centered line once the content chunk is there; as a message row until then. */
function ServiceItem(props: {
  item: MessageItem
  context: MessageRowContext
  content: ChatContent | undefined
  sender: UserRow | undefined
}) {
  const content = props.content
  const chunk = useSignal(content ? content.chunk : noChunk)
  const env = useSignal(content ? content.env : noEnv)
  if (chunk && env && chunk.isServiceRow(props.item.row, env)) return <chunk.ServiceRowView message={props.item.row} env={env} />
  return <MessageItemRow item={props.item} context={props.context} sender={props.sender} />
}

const noChunk = { get: () => undefined, peek: () => undefined }
const noEnv = noChunk

/** One content slot: the content once its chunk is there, else a placeholder of the final size where it is known. */
const ContentSlotItem = memo(function ContentSlotItem(props: {
  message: MessageRow
  slot: ContentSlot
  content: ChatContent
  highlightRanges?: FindRanges
}) {
  const chunk = useSignal(props.content.chunk)
  const env = useSignal(props.content.env)
  if (chunk && env) {
    return (
      <chunk.ContentSlotView
        message={props.message}
        slot={props.slot}
        env={env}
        {...(props.highlightRanges ? { highlightRanges: props.highlightRanges } : {})}
      />
    )
  }
  return props.slot === "above" ? <MediaPlaceholder message={props.message} previews={props.content.previews} /> : null
})

/**
 * A photo's or video's box with its blurred preview, from the row alone
 * (`mediaModel`, as the content view sizes and paints it), so the first
 * frame a row is on shows the preview whether or not the content chunk is
 * there yet; the preview's object URL is the one the content view reuses.
 */
function MediaPlaceholder(props: { message: MessageRow; previews: ChatContent["previews"] }) {
  const media = mediaModel(props.message)
  const preview = media && "preview" in media ? media.preview : undefined
  const previewRef = useElement<HTMLSpanElement>(props.previews.part(preview))
  if (!media || (media.kind !== "photo" && media.kind !== "video" && media.kind !== "gif")) return null
  return (
    <div aria-hidden="true" {...stylex.props(styles.placeholder)}>
      <div {...stylex.props(styles.media, !media.sticker && styles.rounded, dynamic.box(media.box.width, media.box.height))}>
        {preview && <span ref={previewRef} {...stylex.props(styles.preview)} />}
      </div>
    </div>
  )
}

const styles = stylex.create({
  placeholder: { display: "flex", flexDirection: "column", alignItems: "flex-start", minInlineSize: 0, maxInlineSize: "100%" },
  media: {
    position: "relative",
    display: "block",
    flexShrink: 0,
    maxInlineSize: "100%",
    overflow: "hidden",
    isolation: "isolate",
    backgroundColor: `color-mix(in srgb, ${color.label} 8%, transparent)`,
  },
  // The content view's media corner (`mediaMetrics.cornerRadius`).
  rounded: { borderRadius: "13px" },
  // The content view's preview layer (`MediaViews.tsx`, `styles.preview`).
  preview: {
    position: "absolute",
    inset: 0,
    inlineSize: "100%",
    blockSize: "100%",
    backgroundSize: "cover",
    backgroundPosition: "center",
    filter: "blur(12px)",
    transform: "scale(1.12)",
  },
})

const dynamic = stylex.create({
  box: (width: number, height: number) => ({ inlineSize: `${width}px`, aspectRatio: `${width} / ${height}` }),
})
