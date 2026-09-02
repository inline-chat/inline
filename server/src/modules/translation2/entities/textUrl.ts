import { MessageEntity_Type, type MessageEntity } from "@inline-chat/protocol/core"
import { parseMentionMdUrl } from "./mention"
import { parseGroupMentionMdUrl } from "./groupMention"
import { parseThreadMdUrl } from "./thread"
import { parseThreadTitleMdUrl } from "./threadTitle"

export const textUrlEntity = (input: {
  url: string
  offset: number
  length: number
}): MessageEntity | null => {
  if (!input.url || input.length <= 0) {
    return null
  }

  const base = {
    offset: BigInt(input.offset),
    length: BigInt(input.length),
  }

  const mention = parseMentionMdUrl(input.url)
  if (mention) {
    return {
      ...base,
      type: MessageEntity_Type.MENTION,
      entity: {
        oneofKind: "mention",
        mention,
      },
    }
  }

  const groupId = parseGroupMentionMdUrl(input.url)
  if (groupId !== null) {
    return { ...base, type: MessageEntity_Type.GROUP_MENTION,
      entity: { oneofKind: "groupMention", groupMention: { groupId } } }
  }

  const chatId = parseThreadMdUrl(input.url)
  if (chatId) {
    return {
      ...base,
      type: MessageEntity_Type.THREAD,
      entity: {
        oneofKind: "thread",
        thread: { chatId },
      },
    }
  }

  const threadTitle = parseThreadTitleMdUrl(input.url)
  if (threadTitle) {
    return {
      ...base,
      type: MessageEntity_Type.THREAD_TITLE,
      entity: {
        oneofKind: "threadTitle",
        threadTitle,
      },
    }
  }

  return {
    ...base,
    type: MessageEntity_Type.TEXT_URL,
    entity: {
      oneofKind: "textUrl",
      textUrl: { url: input.url },
    },
  }
}
