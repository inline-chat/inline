import {
  DbObjectKind,
  messageKey,
  type Message,
} from "@inline/client"
import { chatId, messageId, userId } from "@inline/ids"
import { describe, expect, it } from "vitest"
import {
  bestPhotoSize,
  makeMessagePresentation,
  messageContentLabel,
  messageMediaDisplaySize,
  messagePresentationMediaDescriptors,
} from "./MessageContent"

const message = (fields: Partial<Message>): Message => ({
  kind: DbObjectKind.Message,
  id: messageKey(chatId(10), messageId(20)),
  messageId: messageId(20),
  chatId: chatId(10),
  fromId: userId(30),
  ...fields,
})

describe("messageContentLabel", () => {
  it("uses Inline protocol media instead of rendering timestamp-only bubbles", () => {
    expect(
      messageContentLabel(
        message({
          media: {
            media: {
              oneofKind: "voice",
              voice: {},
            },
          },
        }),
      ),
    ).toBe("Voice message")
    expect(
      messageContentLabel(
        message({
          media: {
            media: {
              oneofKind: "document",
              document: {
                document: {
                  id: 1n,
                  fileName: "notes.pdf",
                  mimeType: "application/pdf",
                  size: 100,
                  date: 1n,
                },
              },
            },
          },
        }),
      ),
    ).toBe("notes.pdf")
  })

  it("keeps text primary and gives unsupported payloads an honest fallback", () => {
    expect(messageContentLabel(message({ message: "Hello" }))).toBe(
      "Hello",
    )
    expect(messageContentLabel(message({}))).toBe(
      "Unsupported message",
    )
  })

  it("uses InlineKit photo-size priority and reserves stable display geometry", () => {
    const photo = {
      id: 1n,
      date: 1n,
      format: 1,
      sizes: [
        { type: "s", w: 40, h: 30, size: 6, bytes: new Uint8Array([1]) },
        { type: "b", w: 140, h: 140, size: 4_000, cdnUrl: "https://example.com/b" },
        { type: "d", w: 800, h: 600, size: 48_000, cdnUrl: "https://example.com/d" },
      ],
    }
    expect(bestPhotoSize(photo)?.type).toBe("d")
    expect(messageMediaDisplaySize(800, 600, false)).toEqual({ width: 320, height: 240 })
    expect(messageMediaDisplaySize(160, 90, false)).toEqual({ width: 160, height: 90 })
    expect(messageMediaDisplaySize(160, 90, true)).toEqual({ width: 320, height: 180 })
  })

  it("projects Inline stripped bytes into a synchronous tiny thumbnail", () => {
    const presentation = makeMessagePresentation(
      message({
        media: {
          media: {
            oneofKind: "photo",
            photo: {
              photo: {
                id: 1n,
                date: 1n,
                format: 1,
                sizes: [
                  {
                    type: "s",
                    w: 40,
                    h: 30,
                    size: 3,
                    bytes: new Uint8Array([1, 30, 40]),
                  },
                  {
                    type: "d",
                    w: 800,
                    h: 600,
                    size: 1_000,
                    cdnUrl: "https://example.com/photo",
                  },
                ],
              },
            },
          },
        },
      }),
    )

    expect(presentation.media).toEqual(
      expect.objectContaining({
        kind: "photo",
        tinyThumbnailUrl: expect.stringMatching(
          /^data:image\/jpeg;base64,/,
        ),
      }),
    )
  })

  it("collects stable primary, poster, and attachment media identities for first-frame promotion", () => {
    expect(
      messagePresentationMediaDescriptors({
        media: {
          kind: "video",
          mediaKey: "video:10",
          posterKey: "photo:20:d",
          width: 640,
          height: 360,
          animated: false,
          label: "Video",
        },
        attachments: [
          {
            kind: "urlPreview",
            key: "attachment:30",
            title: "Inline",
            thumbnail: { mediaKey: "photo:30:b" },
          },
        ],
      }),
    ).toEqual([
      { key: "video:10" },
      { key: "photo:20:d" },
      { key: "photo:30:b" },
    ])
  })

  it("keeps captions and service messages structurally distinct", () => {
    const photo = makeMessagePresentation(message({
      message: "Caption",
      media: {
        media: {
          oneofKind: "photo",
          photo: {},
        },
      },
    }))
    expect(photo.text).toBe("Caption")
    expect(photo.media?.kind).toBe("photo")

    const service = makeMessagePresentation(message({
      serviceMessage: {
        event: {
          oneofKind: "pinnedMessage",
          pinnedMessage: { messageId: 10n },
        },
      },
    }))
    expect(service).toEqual({ service: "Pinned a message" })
  })

  it("projects protocol URL previews without bigint or unsafe navigation", () => {
    const presentation = makeMessagePresentation(
      message({
        attachments: {
          attachments: [
            {
              id: 44n,
              attachment: {
                oneofKind: "urlPreview",
                urlPreview: {
                  id: 55n,
                  url: "javascript:alert(1)",
                  displayUrl: "https://inline.chat/docs",
                  siteName: "Inline",
                  title: "Inline documentation",
                  description: "A practical guide",
                },
              },
            },
          ],
        },
      }),
    )

    expect(presentation.attachments).toEqual([
      {
        kind: "urlPreview",
        key: "attachment:44",
        url: undefined,
        source: "Inline",
        title: "Inline documentation",
        subtitle: "Inline • A practical guide",
        thumbnail: undefined,
      },
    ])
    expect(() => JSON.stringify(presentation)).not.toThrow()
  })

  it("projects external tasks with exact Inline user identity", () => {
    const taskMessage = message({
      attachments: {
        attachments: [
          {
            id: 77n,
            attachment: {
              oneofKind: "externalTask",
              externalTask: {
                id: 88n,
                taskId: "ENG-42",
                application: "linear",
                title: "Fix message list",
                status: 3,
                assignedUserId: 31n,
                url: "https://linear.app/issue/ENG-42",
                number: "ENG-42",
                date: 1n,
              },
            },
          },
        ],
      },
    })
    expect(messageContentLabel(taskMessage)).toBe("Fix message list")
    expect(makeMessagePresentation(taskMessage).attachments).toEqual([
      {
        kind: "externalTask",
        key: "attachment:77",
        url: "https://linear.app/issue/ENG-42",
        application: "linear",
        number: "ENG-42",
        title: "Fix message list",
        assignedUserId: "31",
      },
    ])
  })
})
