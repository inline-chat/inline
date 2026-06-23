import { describe, expect, test } from "bun:test"
import { RichDirection, type InputPeer, type RichBlock, type RichMediaRef, type RichMessage } from "@inline-chat/protocol/core"
import { RichTextValidationError } from "@in/server/modules/message/richText"
import { buildRichMessageDraftUpdate } from "./richDraftUpdates"

const inputPeer: InputPeer = {
  type: { oneofKind: "chat", chat: { chatId: 42n } },
}

describe("rich draft updates", () => {
  test("builds a transient rich draft update that preserves thinking blocks", () => {
    const update = buildRichMessageDraftUpdate({
      inputPeer,
      currentUserId: 1,
      senderUserId: 2,
      draftId: "chatgpt:run-1",
      messageId: 10n,
      richText: richTextWithThinking(),
      now: new Date("2026-06-22T12:00:00Z"),
      ttlSeconds: 30,
    })

    expect(update.update.oneofKind).toBe("richMessageDraft")
    if (update.update.oneofKind !== "richMessageDraft") {
      throw new Error("Expected richMessageDraft update")
    }

    const draft = update.update.richMessageDraft
    expect(draft.draftId).toBe("chatgpt:run-1")
    expect(draft.senderUserId).toBe(2n)
    expect(draft.messageId).toBe(10n)
    expect(draft.expiresAt).toBe(1782129630n)
    expect(draft.richText?.blocks.map((block) => block.block.oneofKind)).toEqual(["thinking", "paragraph"])
  })

  test("normalizes draft ids before publishing", () => {
    const update = buildRichMessageDraftUpdate({
      inputPeer,
      currentUserId: 1,
      senderUserId: 2,
      draftId: "  chatgpt:run-spaced  ",
      richText: richTextWithThinking(),
    })

    expect(richDraft(update).draftId).toBe("chatgpt:run-spaced")
  })

  test("rejects blank draft ids", () => {
    expect(() =>
      buildRichMessageDraftUpdate({
        inputPeer,
        currentUserId: 1,
        senderUserId: 2,
        draftId: " \t\n ",
        clear: true,
      }),
    ).toThrow(RichTextValidationError)
  })

  test("rejects oversized draft ids", () => {
    expect(() =>
      buildRichMessageDraftUpdate({
        inputPeer,
        currentUserId: 1,
        senderUserId: 2,
        draftId: "x".repeat(257),
        clear: true,
      }),
    ).toThrow(RichTextValidationError)
  })

  test("rejects unresolved public media in draft updates", () => {
    expect(() =>
      buildRichMessageDraftUpdate({
        inputPeer,
        currentUserId: 1,
        senderUserId: 2,
        draftId: "chatgpt:run-2",
        richText: richTextWithPublicPhoto(),
      }),
    ).toThrow(RichTextValidationError)
  })

  test("rejects nested unresolved public media in draft updates", () => {
    expect(() =>
      buildRichMessageDraftUpdate({
        inputPeer,
        currentUserId: 1,
        senderUserId: 2,
        draftId: "chatgpt:run-nested-media",
        richText: richTextWithNestedPublicPhoto(),
      }),
    ).toThrow(RichTextValidationError)
  })

  for (const testCase of [
    ["embed poster", richTextWithEmbedPoster],
    ["embed post author photo", richTextWithEmbedPostAuthorPhoto],
    ["link preview media", richTextWithLinkPreviewMedia],
    ["collage item", richTextWithCollagePublicPhoto],
  ] as const) {
    test(`rejects unresolved public media in draft ${testCase[0]}`, () => {
      expect(() =>
        buildRichMessageDraftUpdate({
          inputPeer,
          currentUserId: 1,
          senderUserId: 2,
          draftId: `chatgpt:run-${testCase[0].replace(/\s+/g, "-")}`,
          richText: testCase[1](),
        }),
      ).toThrow(RichTextValidationError)
    })
  }

  test("builds a clear update without rich text", () => {
    const update = buildRichMessageDraftUpdate({
      inputPeer,
      currentUserId: 1,
      senderUserId: 2,
      draftId: "chatgpt:run-3",
      clear: true,
      now: new Date("2026-06-22T12:00:00Z"),
    })

    expect(update.update.oneofKind).toBe("richMessageDraft")
    if (update.update.oneofKind !== "richMessageDraft") {
      throw new Error("Expected richMessageDraft update")
    }

    expect(update.update.richMessageDraft.clear).toBe(true)
    expect(update.update.richMessageDraft.richText).toBeUndefined()
  })

  test("treats empty rich draft payloads as explicit clears", () => {
    const update = buildRichMessageDraftUpdate({
      inputPeer,
      currentUserId: 1,
      senderUserId: 2,
      draftId: "chatgpt:run-empty",
      richText: {
        version: 1,
        direction: RichDirection.DIRECTION_AUTO,
        fallbackText: "",
        blocks: [],
      },
    })

    const draft = richDraft(update)
    expect(draft.clear).toBe(true)
    expect(draft.richText).toBeUndefined()
  })

  test("clamps draft ttl to keep rich drafts ephemeral", () => {
    const now = new Date("2026-06-22T12:00:00Z")

    const longUpdate = buildRichMessageDraftUpdate({
      inputPeer,
      currentUserId: 1,
      senderUserId: 2,
      draftId: "chatgpt:run-long",
      richText: richTextWithThinking(),
      now,
      ttlSeconds: 86_400,
    })
    const shortUpdate = buildRichMessageDraftUpdate({
      inputPeer,
      currentUserId: 1,
      senderUserId: 2,
      draftId: "chatgpt:run-short",
      richText: richTextWithThinking(),
      now,
      ttlSeconds: -10,
    })
    const invalidUpdate = buildRichMessageDraftUpdate({
      inputPeer,
      currentUserId: 1,
      senderUserId: 2,
      draftId: "chatgpt:run-invalid",
      richText: richTextWithThinking(),
      now,
      ttlSeconds: Number.NaN,
    })

    expect(richDraft(longUpdate).expiresAt).toBe(1782129720n)
    expect(richDraft(shortUpdate).expiresAt).toBe(1782129601n)
    expect(richDraft(invalidUpdate).expiresAt).toBe(1782129630n)
  })
})

function richDraft(update: ReturnType<typeof buildRichMessageDraftUpdate>) {
  if (update.update.oneofKind !== "richMessageDraft") {
    throw new Error("Expected richMessageDraft update")
  }
  return update.update.richMessageDraft
}

function richTextWithThinking(): RichMessage {
  return {
    version: 1,
    direction: RichDirection.DIRECTION_AUTO,
    fallbackText: "",
    blocks: [
      {
        blockId: "thinking",
        direction: RichDirection.DIRECTION_AUTO,
        block: {
          oneofKind: "thinking",
          thinking: {
            initiallyCollapsed: true,
            blocks: [paragraphBlock("private")],
          },
        },
      },
      paragraphBlock("public"),
    ],
  }
}

function richTextWithPublicPhoto(): RichMessage {
  return {
    version: 1,
    direction: RichDirection.DIRECTION_AUTO,
    fallbackText: "",
    blocks: [
      {
        blockId: "photo",
        direction: RichDirection.DIRECTION_AUTO,
        block: {
          oneofKind: "photo",
          photo: {
            media: {
              alt: "",
              media: { oneofKind: "publicUrl", publicUrl: "https://example.com/image.jpg" },
            },
            caption: [],
          },
        },
      },
    ],
  }
}

function richTextWithNestedPublicPhoto(): RichMessage {
  return {
    version: 1,
    direction: RichDirection.DIRECTION_AUTO,
    fallbackText: "",
    blocks: [
      {
        blockId: "details",
        direction: RichDirection.DIRECTION_AUTO,
        block: {
          oneofKind: "details",
          details: {
            title: [{ text: "Progress", children: [], styles: [] }],
            blocks: [richTextWithPublicPhoto().blocks[0]!],
            initiallyOpen: true,
          },
        },
      },
    ],
  }
}

function richTextWithEmbedPoster(): RichMessage {
  return {
    version: 1,
    direction: RichDirection.DIRECTION_AUTO,
    fallbackText: "",
    blocks: [
      {
        blockId: "embed",
        direction: RichDirection.DIRECTION_AUTO,
        block: {
          oneofKind: "embed",
          embed: {
            url: "https://example.com/embed",
            poster: publicPhotoRef(),
            caption: [],
            fullWidth: false,
            allowScrolling: false,
          },
        },
      },
    ],
  }
}

function richTextWithEmbedPostAuthorPhoto(): RichMessage {
  return {
    version: 1,
    direction: RichDirection.DIRECTION_AUTO,
    fallbackText: "",
    blocks: [
      {
        blockId: "embed-post",
        direction: RichDirection.DIRECTION_AUTO,
        block: {
          oneofKind: "embedPost",
          embedPost: {
            url: "https://example.com/post",
            author: "Author",
            authorPhoto: publicPhotoRef(),
            blocks: [paragraphBlock("embedded post")],
            caption: [],
          },
        },
      },
    ],
  }
}

function richTextWithLinkPreviewMedia(): RichMessage {
  return {
    version: 1,
    direction: RichDirection.DIRECTION_AUTO,
    fallbackText: "",
    blocks: [
      {
        blockId: "preview",
        direction: RichDirection.DIRECTION_AUTO,
        block: {
          oneofKind: "linkPreview",
          linkPreview: {
            url: "https://example.com",
            title: "Preview",
            media: publicPhotoRef(),
            compact: false,
          },
        },
      },
    ],
  }
}

function richTextWithCollagePublicPhoto(): RichMessage {
  return {
    version: 1,
    direction: RichDirection.DIRECTION_AUTO,
    fallbackText: "",
    blocks: [
      {
        blockId: "collage",
        direction: RichDirection.DIRECTION_AUTO,
        block: {
          oneofKind: "collage",
          collage: {
            items: [richTextWithPublicPhoto().blocks[0]!],
            caption: [],
          },
        },
      },
    ],
  }
}

function paragraphBlock(text: string): RichBlock {
  return {
    blockId: `paragraph-${text}`,
    direction: RichDirection.DIRECTION_AUTO,
    block: {
      oneofKind: "paragraph",
      paragraph: {
        text: [
          {
            text,
            children: [],
            styles: [],
          },
        ],
      },
    },
  }
}

function publicPhotoRef(): RichMediaRef {
  return {
    alt: "",
    media: { oneofKind: "publicUrl", publicUrl: "https://example.com/image.jpg" },
  }
}
