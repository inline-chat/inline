import { describe, expect, it } from "bun:test"
import type { DbMessage, DbUser } from "@in/server/db/schema"
import type { DbFullMessage } from "@in/server/db/models/messages"
import { encodeFullMessage, encodeMessage } from "@in/server/realtime/encoders/encodeMessage"
import type { Peer } from "@in/protocol/core"

const peer: Peer = {
  type: {
    oneofKind: "user",
    user: { userId: 100n },
  },
}

const baseMessage: DbMessage = {
  globalId: 1n,
  messageId: 1,
  randomId: null,
  text: null,
  textEncrypted: null,
  textIv: null,
  textTag: null,
  entitiesEncrypted: null,
  entitiesIv: null,
  entitiesTag: null,
  chatId: 10,
  fromId: 100,
  editDate: null,
  date: new Date("2025-01-01T00:00:00Z"),
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
  fileId: null,
  isSticker: false,
  hasLink: null,
}

const baseUser: DbUser = {
  id: 100,
  email: null,
  phoneNumber: null,
  emailVerified: null,
  phoneVerified: null,
  firstName: null,
  lastName: null,
  username: null,
  deleted: null,
  online: false,
  lastOnline: null,
  date: new Date("2025-01-01T00:00:00Z"),
  photoFileId: null,
  pendingSetup: null,
  timeZone: null,
  bot: null,
  botCreatorId: null,
}

const buildMessage = (overrides: Partial<DbMessage> = {}): DbMessage => ({
  ...baseMessage,
  ...overrides,
})

const baseFullMessage: DbFullMessage = {
  globalId: 1n,
  messageId: 1,
  randomId: null,
  text: null,
  chatId: 10,
  fromId: 100,
  editDate: null,
  date: new Date("2025-01-01T00:00:00Z"),
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
  fileId: null,
  isSticker: false,
  hasLink: null,
  entities: null,
  from: baseUser,
  reactions: [],
  photo: null,
  video: null,
  document: null,
  messageAttachments: [],
}

const buildFullMessage = (overrides: Partial<DbFullMessage> = {}): DbFullMessage => ({
  ...baseFullMessage,
  ...overrides,
})

describe("encodeMessage nudge", () => {
  it("encodes nudge media when mediaType is nudge", () => {
    const result = encodeMessage({
      message: buildMessage({ text: "👋", mediaType: "nudge" }),
      encodingForUserId: 100,
      encodingForPeer: { peer },
    })

    expect(result.media?.media.oneofKind).toBe("nudge")
  })

  it("does not encode nudge media for emoji-only text", () => {
    const result = encodeMessage({
      message: buildMessage({ text: " 👋 " }),
      encodingForUserId: 100,
      encodingForPeer: { peer },
    })

    expect(result.media?.media.oneofKind).not.toBe("nudge")
  })
})

describe("encodeFullMessage nudge", () => {
  it("encodes nudge media when mediaType is nudge", () => {
    const result = encodeFullMessage({
      message: buildFullMessage({ text: "👋", mediaType: "nudge" }),
      encodingForUserId: 100,
      encodingForPeer: { peer },
    })

    expect(result.media?.media.oneofKind).toBe("nudge")
  })

  it("does not encode nudge media for emoji-only text", () => {
    const result = encodeFullMessage({
      message: buildFullMessage({ text: "👋" }),
      encodingForUserId: 100,
      encodingForPeer: { peer },
    })

    expect(result.media?.media.oneofKind).not.toBe("nudge")
  })
})
