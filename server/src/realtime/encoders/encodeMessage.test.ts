import { beforeEach, describe, expect, it } from "bun:test"
import type { DbMessage, DbUser } from "@in/server/db/schema"
import type { DbFullMessage } from "@in/server/db/models/messages"
import { encodeFullMessage, encodeMessage } from "@in/server/realtime/encoders/encodeMessage"
import { MessageEntities, MessageEntity_Type, type Peer } from "@inline-chat/protocol/core"
import { encryptBinary } from "@in/server/modules/encryption/encryption"

const peer: Peer = {
  type: {
    oneofKind: "user",
    user: { userId: 100n },
  },
}

beforeEach(() => {
  // Needed for encryptBinary() when building encrypted entities for encodeMessage tests.
  process.env["ENCRYPTION_KEY"] = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
})

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
  pinnedAt: null,
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
  updateSeq: null,
  lastUpdateDate: null,
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
  pinnedAt: null,
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

describe("mentioned", () => {
  const mentionedEntities: MessageEntities = {
    entities: [
      {
        type: MessageEntity_Type.MENTION,
        offset: 0n,
        length: 3n,
        entity: { oneofKind: "mention", mention: { userId: 123n } },
      },
    ],
  }

  it("sets mentioned=true when entities mention the encoding user (encodeFullMessage)", () => {
    const result = encodeFullMessage({
      message: buildFullMessage({ entities: mentionedEntities }),
      encodingForUserId: 123,
      encodingForPeer: { peer },
    })

    expect(result.mentioned).toBe(true)
  })

  it("sets mentioned=false when entities do not mention the encoding user (encodeFullMessage)", () => {
    const result = encodeFullMessage({
      message: buildFullMessage({ entities: mentionedEntities }),
      encodingForUserId: 999,
      encodingForPeer: { peer },
    })

    expect(result.mentioned).toBe(false)
  })

  it("sets mentioned=true when entities mention the encoding user (encodeMessage, encrypted entities)", () => {
    const encryptedEntities = encryptBinary(MessageEntities.toBinary(mentionedEntities))

    const result = encodeMessage({
      message: buildMessage({
        entitiesEncrypted: encryptedEntities.encrypted,
        entitiesIv: encryptedEntities.iv,
        entitiesTag: encryptedEntities.authTag,
      }),
      encodingForUserId: 123,
      encodingForPeer: { peer },
    })

    expect(result.mentioned).toBe(true)
  })

  it("sets mentioned=false when there are no entities (encodeMessage)", () => {
    const result = encodeMessage({
      message: buildMessage(),
      encodingForUserId: 123,
      encodingForPeer: { peer },
    })

    expect(result.mentioned).toBe(false)
  })
})
