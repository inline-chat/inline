import type { DbMessage } from "@in/server/db/schema"
import { insertSystemMessage } from "./insert"

const threadBacklinkFallbackText = "Linked from another thread"
const pinnedMessageFallbackText = "Pinned a message"

type InsertSystemEventInput = {
  chatId: number
  actorUserId: number
  date?: Date
}

export async function insertThreadBacklinkSystemMessage(
  input: InsertSystemEventInput & { graphLinkId: bigint; sourceChatId: number; sourceTitle?: string | null },
): Promise<DbMessage> {
  const sourceTitle = normalizedTitle(input.sourceTitle)
  const { message } = await insertSystemMessage({
    chatId: input.chatId,
    actorUserId: input.actorUserId,
    date: input.date,
    fallbackText: sourceTitle ? `Linked from ${sourceTitle}` : threadBacklinkFallbackText,
    payload: {
      event: {
        oneofKind: "threadBacklink",
        threadBacklink: {
          graphLinkId: input.graphLinkId,
          sourceChatId: BigInt(input.sourceChatId),
          sourceTitle,
        },
      },
    },
  })

  return message
}

function normalizedTitle(title: string | null | undefined): string | undefined {
  const trimmed = title?.trim()
  return trimmed && trimmed.length > 0 ? trimmed : undefined
}

export async function insertPinnedMessageSystemMessage(
  input: InsertSystemEventInput & { pinnedMessageGlobalId: bigint; pinnedMessageId: bigint },
): Promise<DbMessage> {
  const { message } = await insertSystemMessage({
    chatId: input.chatId,
    actorUserId: input.actorUserId,
    date: input.date,
    fallbackText: pinnedMessageFallbackText,
    payload: {
      event: {
        oneofKind: "pinnedMessage",
        pinnedMessage: {
          pinnedMessageGlobalId: input.pinnedMessageGlobalId,
          pinnedMessageId: input.pinnedMessageId,
        },
      },
    },
  })

  return message
}
