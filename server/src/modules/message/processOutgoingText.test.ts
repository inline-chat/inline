import { beforeEach, describe, expect, test } from "bun:test"
import { MessageEntity_Type } from "@inline-chat/protocol/core"
import { db } from "@in/server/db"
import { users } from "@in/server/db/schema"
import { processOutgoingText } from "@in/server/modules/message/processOutgoingText"
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
})
