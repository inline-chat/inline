import { describe, expect, it } from "vitest"
import { DbObjectKind, type Message } from "@inline/client"
import { chatId, messageId, userId } from "@inline/ids"
import { chatListPreview } from "./ChatListPreview"

const message = (overrides: Partial<Message> = {}): Message => ({
  kind: DbObjectKind.Message,
  id: `${chatId(1)}:${messageId(2)}`,
  messageId: messageId(2),
  chatId: chatId(1),
  fromId: userId(3),
  ...overrides,
})

describe("chatListPreview", () => {
  it("prefers a bounded draft and always returns content", () => {
    expect(chatListPreview({
      message: message({ message: "old" }),
      draft: { text: "  unfinished\nmessage " },
    })).toBe("Draft: unfinished message")
    expect(chatListPreview({})).toBe("No messages")
  })

  it("covers media-only rows and reply context", () => {
    expect(chatListPreview({
      message: message({
        media: {
          media: {
            oneofKind: "voice",
            voice: { voice: undefined },
          },
        },
      }),
      senderName: "Mo",
      replyThread: true,
    })).toBe("Reply · Mo: Voice message")
    expect(chatListPreview({
      message: message({ isSticker: true, out: true }),
    })).toBe("You: Sticker")
  })

  it("uses document names and compacts text", () => {
    expect(chatListPreview({
      message: message({
        media: {
          media: {
            oneofKind: "document",
            document: {
              document: {
                id: 9n,
                date: 0n,
                fileName: "alpha.pdf",
                mimeType: "application/pdf",
                size: 10,
              },
            },
          },
        },
      }),
    })).toBe("alpha.pdf")
    expect(chatListPreview({
      message: message({ message: "hello\n  world" }),
    })).toBe("hello world")
  })
})
