import { beforeEach, describe, expect, test } from "bun:test"
import { MessageEntity_Type, RichTextStyle } from "@inline-chat/protocol/core"
import { db } from "@in/server/db"
import { users } from "@in/server/db/schema"
import { processOutgoingText } from "@in/server/modules/message/processOutgoingText"
import { RichTextValidationError } from "@in/server/modules/message/richText"
import { setupTestLifecycle, testUtils } from "@in/server/__tests__/setup"
import { eq } from "drizzle-orm"

const runId = Date.now()
let userIndex = 0
const nextEmail = (label: string) => `${label}-${runId}-${userIndex++}@example.com`

describe("processOutgoingText", () => {
  setupTestLifecycle()

  beforeEach(() => {
    userIndex = 0
  })

  test("converts markdown inline user id links to mention entities", async () => {
    const user = await testUtils.createUser(nextEmail("inline-link-id"))

    const result = await processOutgoingText({
      text: `cc [@Mo](inline://user?id=${user.id}) please`,
      entities: undefined,
      parseMarkdown: true,
    })

    expect(result.text).toBe("cc @Mo please")
    expect(result.entities?.entities).toHaveLength(1)

    const mention = result.entities!.entities[0]!
    expect(mention.type).toBe(MessageEntity_Type.MENTION)
    expect(mention.offset).toBe(3n)
    expect(mention.length).toBe(3n)
    expect(mention.entity.oneofKind).toBe("mention")
    if (mention.entity.oneofKind !== "mention") {
      throw new Error("Expected mention entity")
    }
    expect(mention.entity.mention.userId).toBe(BigInt(user.id))
  })

  test("converts markdown inline username links to mention entities", async () => {
    const user = await testUtils.createUser(nextEmail("inline-link-username"))
    await db.update(users).set({ username: "linkedmo" }).where(eq(users.id, user.id)).execute()

    const result = await processOutgoingText({
      text: "cc [@Mo](inline://user?username=LinkedMo) please",
      entities: undefined,
      parseMarkdown: true,
    })

    expect(result.text).toBe("cc @Mo please")
    expect(result.entities?.entities).toHaveLength(1)

    const mention = result.entities!.entities[0]!
    expect(mention.type).toBe(MessageEntity_Type.MENTION)
    expect(mention.entity.oneofKind).toBe("mention")
    if (mention.entity.oneofKind !== "mention") {
      throw new Error("Expected mention entity")
    }
    expect(mention.entity.mention.userId).toBe(BigInt(user.id))
  })

  test("resolves official internal bot aliases to canonical mention entities", async () => {
    const bot = await testUtils.createUser(nextEmail("chatgpt-alias-bot"))
    await db.update(users).set({ username: "chatgpt", bot: true, botCreatorId: null }).where(eq(users.id, bot.id)).execute()

    const conflictingUser = await testUtils.createUser(nextEmail("chat-alias-conflict"))
    await db.update(users).set({ username: "chat" }).where(eq(users.id, conflictingUser.id)).execute()

    const text = "@gpt help and @chat too"
    const result = await processOutgoingText({
      text,
      entities: undefined,
    })

    expect(result.text).toBe(text)
    expect(result.entities?.entities).toHaveLength(2)

    for (const mention of result.entities?.entities ?? []) {
      expect(mention.type).toBe(MessageEntity_Type.MENTION)
      expect(mention.entity.oneofKind).toBe("mention")
      if (mention.entity.oneofKind !== "mention") {
        throw new Error("Expected mention entity")
      }
      expect(mention.entity.mention.userId).toBe(BigInt(bot.id))
    }

    expect(result.entities?.entities[0]).toMatchObject({ offset: 0n, length: 4n })
    expect(result.entities?.entities[1]).toMatchObject({ offset: BigInt(text.indexOf("@chat")), length: 5n })
  })

  test("replaces client username mention entities with resolved internal bot aliases", async () => {
    const bot = await testUtils.createUser(nextEmail("chatgpt-client-username-mention"))
    await db.update(users).set({ username: "chatgpt", bot: true, botCreatorId: null }).where(eq(users.id, bot.id)).execute()

    const result = await processOutgoingText({
      text: "@gpt help",
      entities: {
        entities: [
          {
            type: MessageEntity_Type.USERNAME_MENTION,
            offset: 0n,
            length: 4n,
            entity: { oneofKind: undefined },
          },
        ],
      },
    })

    expect(result.entities?.entities).toHaveLength(1)
    const mention = result.entities!.entities[0]!
    expect(mention).toMatchObject({
      type: MessageEntity_Type.MENTION,
      offset: 0n,
      length: 4n,
    })
    expect(mention.entity.oneofKind).toBe("mention")
    if (mention.entity.oneofKind !== "mention") {
      throw new Error("Expected mention entity")
    }
    expect(mention.entity.mention.userId).toBe(BigInt(bot.id))
  })

  test("converts markdown inline chat links to thread entities", async () => {
    const result = await processOutgoingText({
      text: "cc [Planning](inline://chat?id=42) please",
      entities: undefined,
      parseMarkdown: true,
    })

    expect(result.text).toBe("cc Planning please")
    expect(result.entities?.entities).toHaveLength(1)

    const thread = result.entities!.entities[0]!
    expect(thread.type).toBe(MessageEntity_Type.THREAD)
    expect(thread.offset).toBe(3n)
    expect(thread.length).toBe(8n)
    expect(thread.entity.oneofKind).toBe("thread")
    if (thread.entity.oneofKind !== "thread") {
      throw new Error("Expected thread entity")
    }
    expect(thread.entity.thread.chatId).toBe(42n)
  })

  test("converts markdown inline thread id links to thread entities", async () => {
    const result = await processOutgoingText({
      text: "cc [Planning](inline://thread?id=42) please",
      entities: undefined,
      parseMarkdown: true,
    })

    expect(result.text).toBe("cc Planning please")
    expect(result.entities?.entities).toHaveLength(1)

    const thread = result.entities!.entities[0]!
    expect(thread.type).toBe(MessageEntity_Type.THREAD)
    expect(thread.entity.oneofKind).toBe("thread")
    if (thread.entity.oneofKind !== "thread") {
      throw new Error("Expected thread entity")
    }
    expect(thread.entity.thread.chatId).toBe(42n)
  })

  test("converts markdown inline thread title links to thread title entities", async () => {
    const result = await processOutgoingText({
      text: "cc [Planning](inline://thread?space_id=7) please",
      entities: undefined,
      parseMarkdown: true,
    })

    expect(result.text).toBe("cc Planning please")
    expect(result.entities?.entities).toHaveLength(1)

    const thread = result.entities!.entities[0]!
    expect(thread.type).toBe(MessageEntity_Type.THREAD_TITLE)
    expect(thread.offset).toBe(3n)
    expect(thread.length).toBe(8n)
    expect(thread.entity.oneofKind).toBe("threadTitle")
    if (thread.entity.oneofKind !== "threadTitle") {
      throw new Error("Expected thread title entity")
    }
    expect(thread.entity.threadTitle.spaceId).toBe(7n)
    expect(thread.entity.threadTitle.title).toBe("Planning")
  })

  test("uses inline thread title query when label differs", async () => {
    const result = await processOutgoingText({
      text: "cc [the thread](inline://thread?space_id=7&title=Planning) please",
      entities: undefined,
      parseMarkdown: true,
    })

    expect(result.text).toBe("cc the thread please")
    expect(result.entities?.entities).toHaveLength(1)

    const thread = result.entities!.entities[0]!
    expect(thread.type).toBe(MessageEntity_Type.THREAD_TITLE)
    expect(thread.entity.oneofKind).toBe("threadTitle")
    if (thread.entity.oneofKind !== "threadTitle") {
      throw new Error("Expected thread title entity")
    }
    expect(thread.entity.threadTitle.spaceId).toBe(7n)
    expect(thread.entity.threadTitle.title).toBe("Planning")
  })

  test("keeps invalid inline thread links as text urls", async () => {
    const result = await processOutgoingText({
      text: "cc [Planning](inline://thread) please",
      entities: undefined,
      parseMarkdown: true,
    })

    expect(result.text).toBe("cc Planning please")
    expect(result.entities?.entities).toHaveLength(1)

    const link = result.entities!.entities[0]!
    expect(link.type).toBe(MessageEntity_Type.TEXT_URL)
    expect(link.entity).toEqual({
      oneofKind: "textUrl",
      textUrl: { url: "inline://thread" },
    })
  })

  test("converts explicit inline user text_url entities to mention entities", async () => {
    const user = await testUtils.createUser(nextEmail("inline-link-entity"))

    const result = await processOutgoingText({
      text: "cc @Mo",
      entities: {
        entities: [
          {
            type: MessageEntity_Type.TEXT_URL,
            offset: 3n,
            length: 3n,
            entity: {
              oneofKind: "textUrl",
              textUrl: { url: `inline://user/${user.id}` },
            },
          },
        ],
      },
    })

    expect(result.text).toBe("cc @Mo")
    expect(result.entities?.entities).toHaveLength(1)

    const mention = result.entities!.entities[0]!
    expect(mention.type).toBe(MessageEntity_Type.MENTION)
    expect(mention.offset).toBe(3n)
    expect(mention.length).toBe(3n)
    expect(mention.entity.oneofKind).toBe("mention")
    if (mention.entity.oneofKind !== "mention") {
      throw new Error("Expected mention entity")
    }
    expect(mention.entity.mention.userId).toBe(BigInt(user.id))
  })

  test("trims whitespace from client-provided mention ranges", async () => {
    const result = await processOutgoingText({
      text: "cc @Dena  @Test2  mentions",
      entities: {
        entities: [
          {
            type: MessageEntity_Type.MENTION,
            offset: 3n,
            length: 6n,
            entity: {
              oneofKind: "mention",
              mention: { userId: 10300n },
            },
          },
          {
            type: MessageEntity_Type.MENTION,
            offset: 10n,
            length: 7n,
            entity: {
              oneofKind: "mention",
              mention: { userId: 10600n },
            },
          },
        ],
      },
    })

    expect(result.text).toBe("cc @Dena  @Test2  mentions")
    expect(result.entities?.entities).toHaveLength(2)
    expect(result.entities?.entities[0]).toMatchObject({
      type: MessageEntity_Type.MENTION,
      offset: 3n,
      length: 5n,
    })
    expect(result.entities?.entities[1]).toMatchObject({
      type: MessageEntity_Type.MENTION,
      offset: 10n,
      length: 6n,
    })
  })

  test("prefers inline user id links over username fallbacks", async () => {
    const idUser = await testUtils.createUser(nextEmail("inline-link-id-priority"))
    const usernameUser = await testUtils.createUser(nextEmail("inline-link-username-fallback"))
    await db.update(users).set({ username: "linkedmo" }).where(eq(users.id, usernameUser.id)).execute()

    const result = await processOutgoingText({
      text: `cc [@Mo](inline://user/${idUser.id}?username=linkedmo)`,
      entities: undefined,
      parseMarkdown: true,
    })

    expect(result.entities?.entities).toHaveLength(1)
    const mention = result.entities!.entities[0]!
    expect(mention.entity.oneofKind).toBe("mention")
    if (mention.entity.oneofKind !== "mention") {
      throw new Error("Expected mention entity")
    }
    expect(mention.entity.mention.userId).toBe(BigInt(idUser.id))
  })

  test("keeps unresolved inline user links as text urls", async () => {
    const result = await processOutgoingText({
      text: "cc [@Missing](inline://user?id=99999999)",
      entities: undefined,
      parseMarkdown: true,
    })

    expect(result.text).toBe("cc @Missing")
    expect(result.entities?.entities).toHaveLength(1)

    const entity = result.entities!.entities[0]!
    expect(entity.type).toBe(MessageEntity_Type.TEXT_URL)
    expect(entity.entity).toEqual({
      oneofKind: "textUrl",
      textUrl: { url: "inline://user?id=99999999" },
    })
  })

  test("does not duplicate bare username mentions covered by inline mention links", async () => {
    const user = await testUtils.createUser(nextEmail("inline-link-no-duplicate"))
    await db.update(users).set({ username: "nodupe" }).where(eq(users.id, user.id)).execute()

    const result = await processOutgoingText({
      text: "cc [@nodupe](inline://user?username=nodupe)",
      entities: undefined,
      parseMarkdown: true,
    })

    expect(result.text).toBe("cc @nodupe")
    expect(result.entities?.entities).toHaveLength(1)
    expect(result.entities?.entities[0]?.type).toBe(MessageEntity_Type.MENTION)
  })

  test("parses bot commands from outgoing text", async () => {
    const result = await processOutgoingText({
      text: "/start please",
      entities: undefined,
    })

    expect(result.entities?.entities).toHaveLength(1)
    const command = result.entities!.entities[0]!
    expect(command.type).toBe(MessageEntity_Type.BOT_COMMAND)
    expect(command.offset).toBe(0n)
    expect(command.length).toBe(6n)
    expect(command.entity.oneofKind).toBeUndefined()
  })

  test("can skip automatic bot command detection", async () => {
    const result = await processOutgoingText({
      text: "/start please",
      entities: undefined,
      skipEntityDetection: true,
    })

    expect(result.text).toBe("/start please")
    expect(result.entities).toBeUndefined()
  })

  test("parses bot commands after whitespace with bot username suffix", async () => {
    const result = await processOutgoingText({
      text: "run /deploy@buildbot now",
      entities: undefined,
    })

    expect(result.entities?.entities).toHaveLength(1)
    const command = result.entities!.entities[0]!
    expect(command.type).toBe(MessageEntity_Type.BOT_COMMAND)
    expect(command.offset).toBe(4n)
    expect(command.length).toBe(BigInt("/deploy@buildbot".length))
  })

  test("does not parse bot commands mid-word", async () => {
    const result = await processOutgoingText({
      text: "abc/start",
      entities: undefined,
    })

    expect(result.entities).toBeUndefined()
  })

  test("keeps bot command offsets in utf16 coordinates", async () => {
    const result = await processOutgoingText({
      text: "😀 /start",
      entities: undefined,
    })

    expect(result.entities?.entities).toHaveLength(1)
    const command = result.entities!.entities[0]!
    expect(command.type).toBe(MessageEntity_Type.BOT_COMMAND)
    expect(command.offset).toBe(3n)
    expect(command.length).toBe(6n)
  })

  test("does not parse bot commands covered by markdown code entities", async () => {
    const result = await processOutgoingText({
      text: "Use `/start` today",
      entities: undefined,
      parseMarkdown: true,
    })

    expect(result.text).toBe("Use /start today")
    expect(result.entities?.entities).toHaveLength(1)
    expect(result.entities?.entities[0]?.type).toBe(MessageEntity_Type.CODE)
  })

  test("parses rich markdown into fallback text, rich blocks, and flat entities", async () => {
    const result = await processOutgoingText({
      text: "# Release notes\n\nShip **rich** <u>underlined</u> and ~~struck~~ text with [docs](https://example.com/docs)",
      entities: undefined,
      parseRichMarkdown: true,
    })

    expect(result.text).toBe("Release notes\n\nShip rich underlined and struck text with docs")
    expect(result.richText?.fallbackText).toBe(result.text)
    expect(result.richText?.blocks.map((block) => block.block.oneofKind)).toEqual(["heading", "paragraph"])
    expect(result.entities?.entities.map((entity) => entity.type)).toContain(MessageEntity_Type.BOLD)
    expect(result.entities?.entities.map((entity) => entity.type)).toContain(MessageEntity_Type.UNDERLINE)
    expect(result.entities?.entities.map((entity) => entity.type)).toContain(MessageEntity_Type.STRIKETHROUGH)

    const link = result.entities?.entities.find((entity) => entity.type === MessageEntity_Type.TEXT_URL)
    expect(link?.entity).toEqual({
      oneofKind: "textUrl",
      textUrl: { url: "https://example.com/docs" },
    })
  })

  test("demotes inline-only rich markdown to normal fallback entities", async () => {
    const result = await processOutgoingText({
      text: "Ship **bold**, <u>under</u>, ~~struck~~, `code`, and [docs](https://example.com/docs)",
      entities: undefined,
      parseRichMarkdown: true,
    })

    expect(result.text).toBe("Ship bold, under, struck, code, and docs")
    expect(result.richText).toBeUndefined()
    expect(result.entities?.entities.map((entity) => entity.type)).toEqual(
      expect.arrayContaining([
        MessageEntity_Type.BOLD,
        MessageEntity_Type.UNDERLINE,
        MessageEntity_Type.STRIKETHROUGH,
        MessageEntity_Type.CODE,
        MessageEntity_Type.TEXT_URL,
      ]),
    )
  })

  test("keeps rich markdown when inline content needs rich-only spoiler state", async () => {
    const result = await processOutgoingText({
      text: "Reveal ||secret|| later",
      entities: undefined,
      parseRichMarkdown: true,
    })

    expect(result.text).toBe("Reveal secret later")
    expect(result.richText?.blocks.map((block) => block.block.oneofKind)).toEqual(["paragraph"])
  })

  test("normalizes structured rich text and derives fallback text", async () => {
    const result = await processOutgoingText({
      text: "fallback from caller",
      entities: undefined,
      richText: {
        blocks: [
          {
            blockId: "",
            block: {
              oneofKind: "paragraph",
              paragraph: {
                text: [
                  {
                    text: "structured",
                    children: [],
                    styles: [RichTextStyle.STYLE_BOLD],
                  },
                ],
              },
            },
          },
        ],
        fallbackText: "",
        version: 1,
      },
    })

    expect(result.text).toBe("structured")
    expect(result.richText?.fallbackText).toBe("structured")
    expect(result.entities?.entities).toEqual([
      {
        type: MessageEntity_Type.BOLD,
        offset: 0n,
        length: 10n,
        entity: { oneofKind: undefined },
      },
    ])
  })

  test("normalizes structured rich text without separate text input", async () => {
    const result = await processOutgoingText({
      entities: undefined,
      richText: {
        blocks: [
          {
            blockId: "",
            block: {
              oneofKind: "paragraph",
              paragraph: {
                text: [
                  {
                    text: "rich only",
                    children: [],
                    styles: [RichTextStyle.STYLE_ITALIC],
                  },
                ],
              },
            },
          },
        ],
        fallbackText: "",
        version: 1,
      },
    })

    expect(result.text).toBe("rich only")
    expect(result.richText?.fallbackText).toBe("rich only")
    expect(result.entities?.entities).toEqual([
      {
        type: MessageEntity_Type.ITALIC,
        offset: 0n,
        length: 9n,
        entity: { oneofKind: undefined },
      },
    ])
  })

  test("demotes source-shaped structured rich text only when requested", async () => {
    const richText = {
      blocks: [
        {
          blockId: "",
          block: {
            oneofKind: "paragraph" as const,
            paragraph: {
              text: [{ text: "inline", children: [], styles: [RichTextStyle.STYLE_BOLD] }],
            },
          },
        },
      ],
      fallbackText: "",
      version: 1,
    }

    const kept = await processOutgoingText({
      entities: undefined,
      richText,
    })
    const demoted = await processOutgoingText({
      entities: undefined,
      richText,
      demoteInlineOnlyRichText: true,
    })

    expect(kept.richText?.fallbackText).toBe("inline")
    expect(demoted.richText).toBeUndefined()
    expect(demoted.entities?.entities[0]?.type).toBe(MessageEntity_Type.BOLD)
  })

  test("strips structured thinking blocks unless explicitly allowed", async () => {
    const richText = {
      blocks: [
        {
          blockId: "thinking",
          block: {
            oneofKind: "thinking" as const,
            thinking: {
              initiallyCollapsed: true,
              blocks: [
                {
                  blockId: "",
                  block: {
                    oneofKind: "paragraph" as const,
                    paragraph: { text: [{ text: "private", children: [], styles: [] }] },
                  },
                },
              ],
            },
          },
        },
        {
          blockId: "",
          block: {
            oneofKind: "paragraph" as const,
            paragraph: { text: [{ text: "public", children: [], styles: [] }] },
          },
        },
      ],
      fallbackText: "",
      version: 1,
    }

    const stripped = await processOutgoingText({
      text: "fallback",
      entities: undefined,
      richText,
    })
    const allowed = await processOutgoingText({
      text: "fallback",
      entities: undefined,
      richText,
      allowThinking: true,
    })

    expect(stripped.text).toBe("public")
    expect(stripped.richText?.blocks.map((block) => block.block.oneofKind)).toEqual(["paragraph"])
    expect(allowed.text).toBe("public")
    expect(allowed.richText?.blocks.map((block) => block.block.oneofKind)).toEqual(["thinking", "paragraph"])
  })

  test("rejects final thinking-only rich text instead of leaking supplied fallback", async () => {
    await expect(
      processOutgoingText({
        text: "private fallback",
        entities: undefined,
        richText: {
          blocks: [
            {
              blockId: "thinking",
              block: {
                oneofKind: "thinking" as const,
                thinking: {
                  initiallyCollapsed: true,
                  blocks: [
                    {
                      blockId: "",
                      block: {
                        oneofKind: "paragraph" as const,
                        paragraph: { text: [{ text: "private reasoning", children: [], styles: [] }] },
                      },
                    },
                  ],
                },
              },
            },
          ],
          fallbackText: "private fallback",
          version: 1,
        },
      }),
    ).rejects.toThrow(RichTextValidationError)
  })

  test("rejects rich markdown combined with legacy markdown or entities", async () => {
    await expect(
      processOutgoingText({
        text: "**bold**",
        entities: undefined,
        parseMarkdown: true,
        parseRichMarkdown: true,
      }),
    ).rejects.toThrow(RichTextValidationError)

    await expect(
      processOutgoingText({
        text: "**bold**",
        entities: { entities: [] },
        parseRichMarkdown: true,
      }),
    ).rejects.toThrow(RichTextValidationError)
  })

  test("rejects structured rich text combined with rich markdown parsing", async () => {
    await expect(
      processOutgoingText({
        text: "rich",
        entities: undefined,
        parseRichMarkdown: true,
        richText: {
          blocks: [],
          fallbackText: "rich",
          version: 1,
        },
      }),
    ).rejects.toThrow(RichTextValidationError)
  })
})
