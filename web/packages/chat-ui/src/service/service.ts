/**
 * Service message rows, in the Mac's words (`InlineKit/Models/Message.swift`
 * service segments, `InlineMac/Views/MessageList/ServiceMessageRowView.swift`).
 *
 * A service row is a centered pill of segments, never grouped and without an
 * avatar. Only segments with a `link` are clickable: a user opens their
 * direct chat, a thread opens the thread. Names come from the caller, so this
 * stays free of app state.
 */

import type { MessageRow } from "@inline/core-protocol"
import type { ChatID, MessageID, UserID } from "@inline/ids"

export type ServiceTone = "primary" | "secondary" | "tertiary"

export type ServiceLink = { readonly kind: "user"; readonly userId: UserID } | { readonly kind: "thread"; readonly chatId: ChatID }

export type ServiceSegment = {
  readonly text: string
  readonly tone: ServiceTone
  readonly link?: ServiceLink
}

export type ServiceRowModel = {
  readonly key: string
  readonly segments: readonly ServiceSegment[]
  /** Grid transcripts are left-aligned in a full-width pill; others are centered. */
  readonly align: "center" | "start"
  /** Plain text for copy, previews and accessibility. */
  readonly text: string
  /** Where the event points, for a context action: the pinned message, or the source thread. */
  readonly target: { readonly kind: "message"; readonly messageId: MessageID } | { readonly kind: "thread"; readonly chatId: ChatID } | undefined
}

export type ServiceNames = {
  /** The sender's short name ("Ada"); "Someone" when absent. Ignored for outgoing messages ("You"). */
  readonly sender?: string
}

const transcriptPrefix = "Transcript · "

const actorSegment = (row: Pick<MessageRow, "out" | "fromId">, names: ServiceNames): ServiceSegment => {
  const name = row.out ? "You" : names.sender?.trim() || "Someone"
  const positiveSender = /^[1-9][0-9]*$/.test(row.fromId)
  return { text: name, tone: "secondary", ...(positiveSender ? { link: { kind: "user" as const, userId: row.fromId } } : {}) }
}

/** True for a transcript turn spoken by the sender: it renders as an ordinary message. */
export const isTranscriptSpeech = (row: Pick<MessageRow, "service" | "fromId">): boolean =>
  row.service?.kind === "gridTranscript" && row.service.event === "turn" && row.service.speakerUserId === row.fromId

/**
 * The service row for a message, or undefined when it is not one (no
 * `service`, or a transcript turn by its sender).
 */
export const serviceRowModel = (
  row: Pick<MessageRow, "id" | "service" | "out" | "fromId" | "text" | "entities">,
  names: ServiceNames = {},
): ServiceRowModel | undefined => {
  const service = row.service
  if (!service || isTranscriptSpeech(row)) return undefined
  const key = `service:${row.id}`
  const finish = (
    segments: ServiceSegment[],
    target: ServiceRowModel["target"] = undefined,
    align: ServiceRowModel["align"] = "center",
  ): ServiceRowModel => ({ key, segments, align, text: segments.map((segment) => segment.text).join(""), target })

  switch (service.kind) {
    case "threadBacklink": {
      const actor = actorSegment(row, names)
      const title = service.sourceTitle?.trim()
      const link: ServiceLink | undefined = service.sourceChatId ? { kind: "thread", chatId: service.sourceChatId } : undefined
      const target = service.sourceChatId ? { kind: "thread" as const, chatId: service.sourceChatId } : undefined
      if (title) {
        const linked = link ? { link } : {}
        return finish(
          [
            actor,
            { text: " linked from ", tone: "secondary" },
            { text: "[[", tone: "tertiary", ...linked },
            { text: title, tone: "secondary", ...linked },
            { text: "]]", tone: "tertiary", ...linked },
          ],
          target,
        )
      }
      return finish([actor, { text: " linked to this thread", tone: "secondary" }], target)
    }
    case "pinnedMessage":
      return finish(
        [actorSegment(row, names), { text: " pinned a message", tone: "secondary" }],
        service.messageId ? { kind: "message", messageId: service.messageId } : undefined,
      )
    case "gridTranscript": {
      if (service.event === "turn") {
        const body = row.text.startsWith(transcriptPrefix) ? row.text.slice(transcriptPrefix.length) : row.text
        return finish(
          [
            { text: transcriptPrefix, tone: "tertiary" },
            { text: body, tone: "primary" },
          ],
          undefined,
          "start",
        )
      }
      return finish(statusSegments(row), undefined, "start")
    }
    case "unknown":
      return finish([{ text: row.text, tone: "secondary" }])
  }
}

/** Transcript status rows: the server text, with thread entities as thread links. */
const statusSegments = (row: Pick<MessageRow, "text" | "entities">): ServiceSegment[] => {
  const segments: ServiceSegment[] = []
  const threads = (row.entities ?? [])
    .filter((entity) => entity.type === "thread" && entity.chatId !== undefined)
    .filter((entity) => entity.offset >= 0 && entity.length > 0 && entity.offset + entity.length <= row.text.length)
    .sort((a, b) => a.offset - b.offset)
  let cursor = 0
  for (const entity of threads) {
    if (entity.offset < cursor || !entity.chatId) continue
    if (entity.offset > cursor) segments.push({ text: row.text.slice(cursor, entity.offset), tone: "secondary" })
    segments.push({
      text: row.text.slice(entity.offset, entity.offset + entity.length),
      tone: "secondary",
      link: { kind: "thread", chatId: entity.chatId },
    })
    cursor = entity.offset + entity.length
  }
  if (cursor < row.text.length) segments.push({ text: row.text.slice(cursor), tone: "secondary" })
  return segments
}

/** One-line text for previews when no names are at hand (`MessageService.fallbackText`). */
export const serviceFallbackText = (row: Pick<MessageRow, "service" | "text">): string | undefined => {
  const service = row.service
  switch (service?.kind) {
    case "threadBacklink": {
      const title = service.sourceTitle?.trim()
      return title ? `Linked from ${title}` : "Linked from another thread"
    }
    case "pinnedMessage":
      return "Pinned a message"
    case "gridTranscript":
    case "unknown":
      return row.text
    default:
      return undefined
  }
}
