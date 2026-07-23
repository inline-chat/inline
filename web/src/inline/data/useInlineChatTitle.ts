import { DbObjectKind, type Chat, type Message } from "@inline/client"
import { useInlineObject } from "./react"
import { inlineChatTitle, replyThreadAnchorKey } from "./reply-thread"

export const useInlineChatTitle = (chat?: Chat) => {
  const anchor = useInlineObject<DbObjectKind.Message, Message>(
    DbObjectKind.Message,
    replyThreadAnchorKey(chat),
  )
  return inlineChatTitle(chat, anchor)
}
