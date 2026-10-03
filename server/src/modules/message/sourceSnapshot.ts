import { Message } from "@inline-chat/protocol/core"
import { createHash } from "node:crypto"

/** Hash only the complete public projection used by the preview. This is not
 * an edit revision or an agent direction: asynchronous attachments/images can
 * change it without a new authored message. Encoders supply hydrated data; this
 * helper performs no database or network work. */
export function messageSourceSnapshot(message: Message): string {
  const projection = Message.create({
    id: message.id,
    chatId: message.chatId,
    fromId: message.fromId,
    rev: message.rev,
    message: message.message,
    replyToMsgId: message.replyToMsgId,
    entities: message.entities,
    blockContent: message.blockContent,
    media: message.media,
    // Live encoding omits false; full reads emit it. Bind the logical flag,
    // preserving existing non-sticker tokens across those wire representations.
    isSticker: message.isSticker === true ? true : undefined,
    fwdFrom: message.fwdFrom,
    // Only labels are carried; callback/copy payloads remain with the source.
    actions: message.actions ? { rows: message.actions.rows.map((row) => ({
      actions: row.actions.map((action) => ({ actionId: "", text: action.text, action: { oneofKind: undefined } })),
    })) } : undefined,
    attachments: message.attachments,
    // The existing child link is carried, not its unread/count/author badges.
    subthread: message.subthread ? { chatId: message.subthread.chatId, title: message.subthread.title } : undefined,
    replies: message.replies ? { chatId: message.replies.chatId } : undefined,
  })
  const publicPayload = Message.toJson(projection)
  const canonical = (value: unknown): unknown => {
    if (Array.isArray(value)) return value.map(canonical)
    if (value === null || typeof value !== "object") return value
    return Object.fromEntries(Object.entries(value).filter(([key]) =>
      // Signed CDN locations and decorative upload dates do not identify the
      // captured media. Immutable media/file IDs and readiness remain bound.
      key !== "cdnUrl" && key !== "date" && key !== "bytes" && key !== "displayUrl" && key !== "layout",
    ).sort(([left], [right]) => left.localeCompare(right)).map(([key, child]) => [key, canonical(child)]))
  }
  return createHash("sha256").update(JSON.stringify({ version: 1, projection: canonical(publicPayload) })).digest("hex")
}
