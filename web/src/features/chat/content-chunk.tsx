/**
 * The message content chunk (see `chat-content.ts` for the loading rule):
 * the content environment and the two components the message list uses from
 * `web/src/features/content/`. Nothing imports this statically; the app
 * loads it with a dynamic import (`AppViews.content`).
 */

import type { MessageRow } from "@inline/core-protocol"
import type { ReactNode } from "react"
import { createContentEnv, MessageContent, ServiceRow, type ContentEnv } from "../content"
import { CONTENT_SLOT_SECTIONS, type ContentSlot, type FindRanges } from "../message"
import { serviceRowModel } from "@inline/chat-ui"

export { createContentEnv }
/** The real media layer over the core's `media` query (`features/media`), created once per session. */
export { createCoreMediaSources } from "../media/sources"
/** What the content calls in the pane, and how it names people. */
export { contentHandlers, contentNames } from "./content-handlers"

/** One content slot of a message row. `highlightRanges`: find matches in a rich-block message's text. */
export function ContentSlotView(props: { message: MessageRow; slot: ContentSlot; env: ContentEnv; highlightRanges?: FindRanges }) {
  return (
    <MessageContent
      message={props.message}
      env={props.env}
      sections={CONTENT_SLOT_SECTIONS[props.slot]}
      {...(props.highlightRanges ? { highlightRanges: props.highlightRanges } : {})}
    />
  )
}

/** Whether a message draws as a service row (a centered line) rather than a message row. */
export const isServiceRow = (message: MessageRow, env: ContentEnv): boolean => {
  if (message.service === undefined) return false
  const sender = env.names.user?.(message.fromId)?.name
  return serviceRowModel(message, sender ? { sender } : {}) !== undefined
}

/** A service message's row. */
export function ServiceRowView(props: { message: MessageRow; env: ContentEnv }): ReactNode {
  return <ServiceRow message={props.message} env={props.env} />
}

export type ContentChunk = typeof import("./content-chunk")
