import { describe, expect, it } from "bun:test"
import type { DbChat, DbMessage } from "@in/server/db/schema"
import { buildSystemMessageUpdate } from "./insert"

const chat: DbChat = {
  id: 10,
  type: "thread",
  title: "Roadmap",
  description: null,
  lastMsgId: 7,
  spaceId: null,
  publicThread: null,
  threadNumber: null,
  createdBy: 100,
  isUntitled: false,
  parentChatId: null,
  parentMessageId: null,
  minUserId: null,
  maxUserId: null,
  date: new Date("2026-01-01T00:00:00Z"),
  emoji: null,
  updateSeq: 9,
  lastUpdateDate: new Date("2026-01-01T00:00:01Z"),
}

const baseMessage: DbMessage = {
  globalId: 77n,
  messageId: 7,
  randomId: null,
  text: null,
  textEncrypted: null,
  textIv: null,
  textTag: null,
  entitiesEncrypted: null,
  entitiesIv: null,
  entitiesTag: null,
  actionsEncrypted: null,
  actionsIv: null,
  actionsTag: null,
  systemMessageEncrypted: null,
  systemMessageIv: null,
  systemMessageTag: null,
  chatId: 10,
  fromId: 100,
  editDate: null,
  rev: 0,
  date: new Date("2026-01-01T00:00:00Z"),
  replyToMsgId: null,
  fwdFromPeerUserId: null,
  fwdFromPeerChatId: null,
  fwdFromMessageId: null,
  fwdFromSenderId: null,
  groupedId: null,
  mediaType: null,
  photoId: null,
  videoId: null,
  documentId: null,
  voiceId: null,
  fileId: null,
  isSticker: false,
  pinnedAt: null,
  hasLink: false,
}

describe("system message insertion updates", () => {
  it("builds a public service-message update with fallback text", () => {
    const update = buildSystemMessageUpdate({
      chat,
      targetUserId: 200,
      update: {
        seq: 11,
        date: new Date("2026-01-01T00:00:02Z"),
      },
      message: {
        ...baseMessage,
        text: "Pinned a message",
        systemMessage: {
          event: {
            oneofKind: "pinnedMessage",
            pinnedMessage: {
              pinnedMessageGlobalId: 55n,
              pinnedMessageId: 4n,
            },
          },
        },
      },
    })

    expect(update.seq).toBe(11)
    expect(update.update.oneofKind).toBe("newMessage")
    if (update.update.oneofKind !== "newMessage") {
      throw new Error("expected newMessage update")
    }

    const message = update.update.newMessage.message
    expect(message?.message).toBe("Pinned a message")
    expect(message?.serviceMessage?.event.oneofKind).toBe("pinnedMessage")
    if (message?.serviceMessage?.event.oneofKind !== "pinnedMessage") {
      throw new Error("expected pinned service message")
    }
    expect(message.serviceMessage.event.pinnedMessage.messageId).toBe(4n)
  })
})
