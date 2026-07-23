import {
  DbObjectKind,
  messageKey,
  type Message,
} from "@inline/client"
import { chatId, messageId, userId } from "@inline/ids"
import { describe, expect, it } from "vitest"
import { makeChatMessageRow } from "./ChatRowListModel"

describe("ChatRowListModel", () => {
  it("keeps lossless protocol payloads out of React row props", () => {
    const message: Message = {
      kind: DbObjectKind.Message,
      id: messageKey(chatId(10), messageId(20)),
      messageId: messageId(20),
      chatId: chatId(10),
      fromId: userId(30),
      replies: {
        chatId: 90n,
        replyCount: 2,
        hasUnread: true,
        recentReplierUserIds: [30n, 31n],
      },
      media: {
        media: {
          oneofKind: "voice",
          voice: {},
        },
      },
    }

    const row = makeChatMessageRow(message)

    expect(row.presentation.media).toMatchObject({
      kind: "voice",
      label: "Voice message",
    })
    expect(JSON.stringify(row)).toContain("Voice message")
    expect(row).not.toHaveProperty("media")
    expect(row).not.toHaveProperty("replies")
    expect(row.replyThreadSummary).toEqual({
      chatId: "90",
      replyCount: 2,
      hasUnread: true,
      recentReplierUserIds: ["30", "31"],
    })
    expect(() => JSON.stringify(row)).not.toThrow()
  })

  it("projects media identity and dimensions without bigint values", () => {
    const message: Message = {
      kind: DbObjectKind.Message,
      id: messageKey(chatId(10), messageId(21)),
      messageId: messageId(21),
      chatId: chatId(10),
      fromId: userId(30),
      media: {
        media: {
          oneofKind: "photo",
          photo: {
            photo: {
              id: 500n,
              date: 1n,
              format: 1,
              sizes: [
                { type: "b", w: 140, h: 100, size: 20, cdnUrl: "https://example.com/b" },
                { type: "d", w: 800, h: 600, size: 80, cdnUrl: "https://example.com/d" },
              ],
            },
          },
        },
      },
    }

    const row = makeChatMessageRow(message)
    expect(row.presentation.media).toEqual({
      kind: "photo",
      mediaKey: "photo:500:d",
      remoteUrl: "https://example.com/d",
      width: 800,
      height: 600,
      label: "Photo",
    })
    expect(() => JSON.stringify(row)).not.toThrow()
    expect(JSON.stringify(row)).not.toContain("500n")
  })

  it("reserves an embedded-reply row before its bounded reference loads", () => {
    const message: Message = {
      kind: DbObjectKind.Message,
      id: messageKey(chatId(10), messageId(22)),
      messageId: messageId(22),
      chatId: chatId(10),
      fromId: userId(30),
      replyToMsgId: messageId(5),
      message: "Reply",
    }
    expect(makeChatMessageRow(message).embeddedReply).toEqual({
      messageId: "5",
    })

    const referenced: Message = {
      kind: DbObjectKind.Message,
      id: messageKey(chatId(10), messageId(5)),
      messageId: messageId(5),
      chatId: chatId(10),
      fromId: userId(31),
      message: "Original",
    }
    expect(
      makeChatMessageRow(message, referenced).embeddedReply,
    ).toEqual({
      messageId: "5",
      fromId: "31",
      presentation: { text: "Original" },
    })
  })

  it("projects a lossless forward source into branded route identity", () => {
    const message: Message = {
      kind: DbObjectKind.Message,
      id: messageKey(chatId(10), messageId(23)),
      messageId: messageId(23),
      chatId: chatId(10),
      fromId: userId(30),
      message: "Forwarded",
      fwdFrom: {
        fromPeerId: {
          type: {
            oneofKind: "chat",
            chat: { chatId: 90n },
          },
        },
        fromId: 31n,
        fromMessageId: 5n,
      },
    }
    expect(makeChatMessageRow(message).forwardHeader).toEqual({
      fromPeer: { peerKind: "chat", peerId: "90" },
      fromId: "31",
      fromMessageId: "5",
    })
    expect(() => JSON.stringify(makeChatMessageRow(message))).not.toThrow()
  })

  it("projects reactions and optimistic intents without bigint values", () => {
    const message: Message = {
      kind: DbObjectKind.Message,
      id: messageKey(chatId(10), messageId(24)),
      messageId: messageId(24),
      chatId: chatId(10),
      fromId: userId(30),
      message: "Reacted",
      reactions: {
        reactions: [{
          emoji: "👍",
          userId: 31n,
          messageId: 24n,
          chatId: 10n,
          date: 1_720_000_000n,
        }],
      },
      reactionIntents: [{
        id: "intent-1",
        emoji: "👍",
        userId: userId(30),
        action: "add",
      }],
    }
    expect(makeChatMessageRow(message).reactions).toEqual({
      reactions: [{ emoji: "👍", userId: "31", date: 1_720_000_000 }],
      intents: [{
        id: "intent-1",
        emoji: "👍",
        userId: "30",
        action: "add",
      }],
    })
    expect(() => JSON.stringify(makeChatMessageRow(message))).not.toThrow()
  })
})
