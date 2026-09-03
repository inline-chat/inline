import { beforeEach, describe, expect, it } from "bun:test"
import type { DbMessage, DbUser } from "@in/server/db/schema"
import type { DbFullMessage } from "@in/server/db/models/messages"
import type { DbFullPhoto, DbFullVoice } from "@in/server/db/models/files"
import { encodeFullMessage, encodeMessage } from "@in/server/realtime/encoders/encodeMessage"
import {
  BlockDisclosure_ActivityKind,
  BlockDisclosure_Kind,
  MessageEntities,
  MessageEntity_Type,
  Photo_Format,
  type Peer,
} from "@inline-chat/protocol/core"
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
  systemMessageEncrypted: null,
  systemMessageIv: null,
  systemMessageTag: null,
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
  blockContentId: null,
  countsAsUnread: true,
}

const baseUser: DbUser = {
  id: 100,
  email: null,
  phoneNumber: null,
  emailVerified: null,
  phoneVerified: null,
  firstName: null,
  lastName: null,
  bio: null,
  username: null,
  deleted: null,
  online: false,
  lastOnline: null,
  date: new Date("2025-01-01T00:00:00Z"),
  photoFileId: null,
  pendingSetup: null,
  timeZone: null,
  nextThreadNumber: 1,
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
  blockContentId: null,
  countsAsUnread: true,
  entities: null,
  actions: null,
  systemMessage: null,
  blockContent: null,
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

const currentBlockPhoto: DbFullPhoto = {
  id: 42,
  format: "png",
  width: 640,
  height: 480,
  stripped: null,
  strippedIv: null,
  strippedTag: null,
  date: new Date("2025-02-01T00:00:00Z"),
  photoSizes: [{
    id: 43,
    fileId: 44,
    photoId: 42,
    size: "f",
    width: 640,
    height: 480,
    file: {
      ...voice.file,
      id: 44,
      fileUniqueId: "PHO_CURRENT_BLOCK",
      fileSize: 777,
      mimeType: "image/png",
      fileType: "photo",
      width: 640,
      height: 480,
    },
  }],
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

describe("encodeFullMessage block photos", () => {
  it("projects current ready photos through nested blocks and preserves missing snapshots", () => {
    const staleCurrent = {
      id: 42n,
      date: 1n,
      format: Photo_Format.JPEG,
      sizes: [{ type: "f", w: 1, h: 1, size: 1, cdnUrl: "https://expired.invalid/current" }],
    }
    const staleMissing = {
      id: 404n,
      date: 2n,
      format: Photo_Format.JPEG,
      sizes: [{ type: "f", w: 2, h: 2, size: 2, cdnUrl: "https://expired.invalid/missing" }],
    }
    const blockContent = {
      blocks: [{
        kind: {
          oneofKind: "disclosure" as const,
          disclosure: {
            summary: { offset: 0n, length: 0n },
            kind: BlockDisclosure_Kind.DEFAULT,
            activityKind: BlockDisclosure_ActivityKind.UNSPECIFIED,
            children: [{
              kind: {
                oneofKind: "album" as const,
                album: {
                  images: [
                    { alt: { offset: 0n, length: 0n }, state: { oneofKind: "ready" as const, ready: staleCurrent } },
                    { alt: { offset: 0n, length: 0n }, state: { oneofKind: "ready" as const, ready: staleMissing } },
                  ],
                },
              },
            }],
          },
        },
      }],
    }

    const result = encodeFullMessage({
      message: buildFullMessage({
        text: "",
        blockContent,
        blockContentPhotos: new Map([[42n, currentBlockPhoto]]),
      }),
      encodingForUserId: 100,
      encodingForPeer: { peer },
    })

    const disclosure = result.blockContent?.blocks[0]
    expect(disclosure?.kind.oneofKind).toBe("disclosure")
    if (disclosure?.kind.oneofKind !== "disclosure") throw new Error("Expected disclosure")
    const album = disclosure.kind.disclosure.children[0]
    if (album?.kind.oneofKind !== "album") throw new Error("Expected album")
    const [projectedCurrent, projectedMissing] = album.kind.album.images
    expect(projectedCurrent?.state.oneofKind).toBe("ready")
    if (projectedCurrent?.state.oneofKind !== "ready") throw new Error("Expected ready photo")
    expect(projectedCurrent.state.ready.format).toBe(Photo_Format.PNG)
    expect(projectedCurrent.state.ready.sizes[0]?.size).toBe(777)
    expect(projectedMissing?.state.oneofKind).toBe("ready")
    if (projectedMissing?.state.oneofKind !== "ready") throw new Error("Expected ready fallback")
    expect(projectedMissing.state.ready.sizes[0]?.cdnUrl).toBe("https://expired.invalid/missing")

    expect(staleCurrent.sizes[0]?.cdnUrl).toBe("https://expired.invalid/current")
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

  it("derives voice MIME from storage extension when an old row is missing MIME", () => {
    const result = encodeMessage({
      message: buildMessage({ mediaType: "voice", voiceId: 9 }),
      voice: {
        ...voice,
        file: {
          ...voice.file,
          mimeType: null,
          path: "voices/voice-9.m4a",
        },
      },
      encodingForUserId: 100,
      encodingForPeer: { peer },
    })

    expect(result.media?.media.oneofKind).toBe("voice")
    if (result.media?.media.oneofKind !== "voice") {
      throw new Error("Expected voice media")
    }
    expect(result.media.media.voice.voice?.mimeType).toBe("audio/mp4")
  })

  it("derives voice MIME from storage extension when an old row has unsupported MIME", () => {
    const result = encodeMessage({
      message: buildMessage({ mediaType: "voice", voiceId: 9 }),
      voice: {
        ...voice,
        file: {
          ...voice.file,
          mimeType: "application/octet-stream",
          path: "voices/voice-9.m4a",
        },
      },
      encodingForUserId: 100,
      encodingForPeer: { peer },
    })

    expect(result.media?.media.oneofKind).toBe("voice")
    if (result.media?.media.oneofKind !== "voice") {
      throw new Error("Expected voice media")
    }
    expect(result.media.media.voice.voice?.mimeType).toBe("audio/mp4")
  })

  it("does not encode mislabelled voice media", () => {
    const result = encodeMessage({
      message: buildMessage({ mediaType: "voice", voiceId: 9 }),
      voice: {
        ...voice,
        file: {
          ...voice.file,
          mimeType: "audio/ogg",
          path: "voices/voice-9.m4a",
        },
      },
      encodingForUserId: 100,
      encodingForPeer: { peer },
    })

    expect(result.media).toBeUndefined()
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

describe("service messages", () => {
  it("encodes thread backlink service metadata on full messages", () => {
    const result = encodeFullMessage({
      message: buildFullMessage({
        text: "Linked from Source",
        systemMessage: {
          event: {
            oneofKind: "threadBacklink",
            threadBacklink: { graphLinkId: 42n, sourceChatId: 10n, sourceTitle: "Source" },
          },
        },
      }),
      encodingForUserId: 100,
      encodingForPeer: { peer },
    })

    expect(result.message).toBe("Linked from Source")
    expect(result.serviceMessage?.event.oneofKind).toBe("threadBacklink")
    if (result.serviceMessage?.event.oneofKind !== "threadBacklink") {
      throw new Error("expected thread backlink service message")
    }
    expect(result.serviceMessage.event.threadBacklink.sourceChatId).toBe(10n)
    expect(result.serviceMessage.event.threadBacklink.sourceTitle).toBe("Source")
  })

  it("encodes pinned message service metadata with target message id", () => {
    const result = encodeFullMessage({
      message: buildFullMessage({
        text: "Pinned a message",
        systemMessage: {
          event: {
            oneofKind: "pinnedMessage",
            pinnedMessage: {
              pinnedMessageGlobalId: 900n,
              pinnedMessageId: 12n,
            },
          },
        },
      }),
      encodingForUserId: 100,
      encodingForPeer: { peer },
    })

    expect(result.message).toBe("Pinned a message")
    expect(result.serviceMessage?.event.oneofKind).toBe("pinnedMessage")
    if (result.serviceMessage?.event.oneofKind !== "pinnedMessage") {
      throw new Error("Expected pinned message service metadata")
    }
    expect(result.serviceMessage.event.pinnedMessage.messageId).toBe(12n)
  })

  it("encodes service metadata on non-full processed messages when present", () => {
    const result = encodeMessage({
      message: {
        ...buildMessage({ text: "Pinned a message" }),
        systemMessage: {
          event: {
            oneofKind: "pinnedMessage",
            pinnedMessage: {
              pinnedMessageGlobalId: 901n,
              pinnedMessageId: 13n,
            },
          },
        },
      },
      encodingForUserId: 100,
      encodingForPeer: { peer },
    })

    expect(result.serviceMessage?.event.oneofKind).toBe("pinnedMessage")
    if (result.serviceMessage?.event.oneofKind !== "pinnedMessage") {
      throw new Error("Expected pinned message service metadata")
    }
    expect(result.serviceMessage.event.pinnedMessage.messageId).toBe(13n)
  })
})
