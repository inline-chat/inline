import { beforeEach, describe, expect, it } from "bun:test"
import type { DbMessage, DbUser } from "@in/server/db/schema"
import type { DbFullMessage } from "@in/server/db/models/messages"
import type { DbFullVoice } from "@in/server/db/models/files"
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
  actionsEncrypted: null,
  actionsIv: null,
  actionsTag: null,
  chatId: 10,
  fromId: 100,
  editDate: null,
  rev: 0,
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
  voiceId: null,
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
  rev: 0,
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
  voiceId: null,
  fileId: null,
  isSticker: false,
  pinnedAt: null,
  hasLink: null,
  entities: null,
  actions: null,
  from: baseUser,
  reactions: [],
  photo: null,
  video: null,
  document: null,
  voice: null,
  messageAttachments: [],
}

const buildFullMessage = (overrides: Partial<DbFullMessage> = {}): DbFullMessage => ({
  ...baseFullMessage,
  ...overrides,
})

const voice: DbFullVoice = {
  id: 9,
  fileId: 10,
  date: new Date("2025-01-01T00:00:00Z"),
  duration: 12,
  waveform: Buffer.from([1, 2, 3]),
  file: {
    id: 10,
    fileUniqueId: "INV_TEST",
    userId: 100,
    date: new Date("2025-01-01T00:00:00Z"),
    fileSize: 321,
    mimeType: "audio/ogg",
    cdn: 1,
    fileType: "voice",
    videoDuration: null,
    thumbSize: null,
    thumbFor: null,
    bytesEncrypted: null,
    bytesIv: null,
    bytesTag: null,
    nameEncrypted: null,
    nameIv: null,
    nameTag: null,
    width: null,
    height: null,
    path: null,
  },
}

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

describe("encode voice", () => {
  it("encodes voice media when voice is present", () => {
    const result = encodeMessage({
      message: buildMessage({ mediaType: "voice", voiceId: 9 }),
      voice,
      encodingForUserId: 100,
      encodingForPeer: { peer },
    })

    expect(result.media?.media.oneofKind).toBe("voice")
    if (result.media?.media.oneofKind !== "voice") {
      throw new Error("Expected voice media")
    }
    const encodedVoice = result.media.media.voice.voice
    expect(encodedVoice).toBeTruthy()
    expect(encodedVoice?.duration).toBe(12)
  })

  it("encodes full voice media when full message has a voice relation", () => {
    const result = encodeFullMessage({
      message: buildFullMessage({ mediaType: "voice", voiceId: 9, voice }),
      encodingForUserId: 100,
      encodingForPeer: { peer },
    })

    expect(result.media?.media.oneofKind).toBe("voice")
    if (result.media?.media.oneofKind !== "voice") {
      throw new Error("Expected voice media")
    }
    const encodedVoice = result.media.media.voice.voice
    expect(encodedVoice).toBeTruthy()
    expect(encodedVoice?.waveform).toEqual(new Uint8Array([1, 2, 3]))
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
