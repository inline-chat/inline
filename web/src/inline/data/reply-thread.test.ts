import { DbObjectKind, messageKey, type Chat, type Message } from "@inline/client"
import { chatId, messageId, userId } from "@inline/ids"
import { describe, expect, it } from "vitest"
import { inlineChatTitle, replyThreadAnchorKey } from "./reply-thread"

const chat = (changes: Partial<Chat> = {}): Chat => ({
  kind: DbObjectKind.Chat,
  id: chatId(20),
  ...changes,
})

const anchor = (text?: string): Message => ({
  kind: DbObjectKind.Message,
  id: messageKey(chatId(10), messageId(7)),
  messageId: messageId(7),
  chatId: chatId(10),
  fromId: userId(1),
  message: text,
})

describe("Inline reply-thread titles", () => {
  it("keeps an explicit title", () => {
    expect(
      inlineChatTitle(
        chat({
          title: "  Project launch  ",
          parentChatId: chatId(10),
          parentMessageId: messageId(7),
        }),
        anchor("Ignored"),
      ),
    ).toBe("Project launch")
  })

  it("uses the normalized parent-message excerpt for untitled reply threads", () => {
    expect(
      inlineChatTitle(
        chat({
          parentChatId: chatId(10),
          parentMessageId: messageId(7),
        }),
        anchor("  An update\n\nwith   spacing  "),
      ),
    ).toBe("Re: An update with spacing")
  })

  it("uses the native generic fallback until its anchor is available", () => {
    expect(
      inlineChatTitle(
        chat({
          parentChatId: chatId(10),
          parentMessageId: messageId(7),
        }),
      ),
    ).toBe("Re: Message")
  })

  it("keeps New thread for an untitled top-level thread", () => {
    expect(inlineChatTitle(chat())).toBe("New thread")
  })

  it("addresses anchors with the parent chat and message ID", () => {
    expect(
      replyThreadAnchorKey(
        chat({
          parentChatId: chatId(10),
          parentMessageId: messageId(7),
        }),
      ),
    ).toBe("10:7")
  })
})
