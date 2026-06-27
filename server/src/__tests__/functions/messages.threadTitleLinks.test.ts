import { describe, expect, test } from "bun:test"
import { MessageEntity_Type, type Message, type MessageEntities } from "@inline-chat/protocol/core"
import { db, schema } from "@in/server/db"
import { getChatHistory } from "@in/server/functions/messages.getChatHistory"
import { sendMessage } from "@in/server/functions/messages.sendMessage"
import { setupTestLifecycle, testUtils } from "@in/server/__tests__/setup"
import { and, eq, isNull } from "drizzle-orm"

setupTestLifecycle()

describe("messages thread title links", () => {
  test("resolves thread-title entities to an existing thread before graph materialization", async () => {
    const { space, users } = await testUtils.createSpaceWithMembers("Graph Title Existing", [
      "graph-title-existing@example.com",
    ])
    const user = users[0]!
    const source = await testUtils.createChat(space.id, "Source", "thread", true, user.id)
    const target = await testUtils.createChat(space.id, "Planning", "thread", true, user.id)
    if (!source || !target) {
      throw new Error("Failed to create title-link test threads")
    }

    const sent = await sendMessage(
      {
        peerId: { type: { oneofKind: "chat", chat: { chatId: BigInt(source.id) } } },
        message: "see Planning",
        entities: threadTitleEntities({ spaceId: space.id, title: "Planning", offset: 4, length: 8 }),
      },
      testUtils.functionContext({ userId: user.id, sessionId: 1 }),
    )

    const message = extractNewMessage(sent)
    expect(message).toBeTruthy()
    expect(messageThreadTarget(message)).toBe(BigInt(target.id))

    await expectGraphLink({
      fromChatId: source.id,
      fromMessageId: Number(message?.id),
      toChatId: target.id,
      scopeId: space.id,
    })

    const targetHistory = await getChatHistory(
      { peerId: { type: { oneofKind: "chat", chat: { chatId: BigInt(target.id) } } }, limit: 1 },
      testUtils.functionContext({ userId: user.id, sessionId: 2 }),
    )
    expect(targetHistory.messages).toHaveLength(1)
    expect(targetHistory.messages[0]?.message).toBe("Linked from Source")
    expect(targetHistory.messages[0]?.serviceMessage?.event.oneofKind).toBe("threadBacklink")
    if (targetHistory.messages[0]?.serviceMessage?.event.oneofKind !== "threadBacklink") {
      throw new Error("Expected thread backlink service message")
    }
    expect(targetHistory.messages[0]?.serviceMessage?.event.threadBacklink.sourceChatId).toBe(BigInt(source.id))
    expect(targetHistory.messages[0]?.serviceMessage?.event.threadBacklink.sourceTitle).toBe("Source")
  })

  test("creates a missing thread-title target before graph materialization", async () => {
    const { space, users } = await testUtils.createSpaceWithMembers("Graph Title Missing", [
      "graph-title-missing@example.com",
    ])
    const user = users[0]!
    const source = await testUtils.createChat(space.id, "Source", "thread", true, user.id)
    if (!source) {
      throw new Error("Failed to create source thread")
    }

    const sent = await sendMessage(
      {
        peerId: { type: { oneofKind: "chat", chat: { chatId: BigInt(source.id) } } },
        message: "see Roadmap",
        entities: threadTitleEntities({ spaceId: space.id, title: "Roadmap", offset: 4, length: 7 }),
      },
      testUtils.functionContext({ userId: user.id, sessionId: 1 }),
    )

    const [target] = await db
      .select()
      .from(schema.chats)
      .where(and(eq(schema.chats.spaceId, space.id), eq(schema.chats.title, "Roadmap")))
      .limit(1)

    expect(target).toBeTruthy()
    expect(target?.publicThread).toBe(true)
    expect(target?.createdBy).toBe(user.id)

    const message = extractNewMessage(sent)
    expect(message).toBeTruthy()
    expect(messageThreadTarget(message)).toBe(BigInt(target!.id))

    await expectGraphLink({
      fromChatId: source.id,
      fromMessageId: Number(message?.id),
      toChatId: target!.id,
      scopeId: space.id,
    })
  })

  test("creates a missing home thread-title target before graph materialization", async () => {
    const user = await testUtils.createUser("graph-title-home@example.com")
    const source = await testUtils.createChat(null, "Home Source", "thread", false, user.id)
    if (!source) {
      throw new Error("Failed to create home source thread")
    }

    await testUtils.addParticipant(source.id, user.id)

    const sent = await sendMessage(
      {
        peerId: { type: { oneofKind: "chat", chat: { chatId: BigInt(source.id) } } },
        message: "see Personal",
        entities: threadTitleEntities({ spaceId: 0, title: "Personal", offset: 4, length: 8 }),
      },
      testUtils.functionContext({ userId: user.id, sessionId: 1 }),
    )

    const [target] = await db
      .select()
      .from(schema.chats)
      .where(and(isNull(schema.chats.spaceId), eq(schema.chats.title, "Personal")))
      .limit(1)

    expect(target).toBeTruthy()
    expect(target?.publicThread).toBe(false)
    expect(target?.createdBy).toBe(user.id)

    const message = extractNewMessage(sent)
    expect(message).toBeTruthy()
    expect(messageThreadTarget(message)).toBe(BigInt(target!.id))

    await expectGraphLink({
      fromChatId: source.id,
      fromMessageId: Number(message?.id),
      toChatId: target!.id,
      scopeType: "user",
      scopeId: user.id,
    })
  })

  test("resolves home thread-title links to the current user's existing home thread", async () => {
    const user = await testUtils.createUser("graph-title-home-existing@example.com")
    const other = await testUtils.createUser("graph-title-home-existing-other@example.com")
    const source = await testUtils.createChat(null, "Home Existing Source", "thread", false, user.id)
    const target = await testUtils.createChat(null, "Personal", "thread", false, user.id)
    const otherTarget = await testUtils.createChat(null, "Personal", "thread", false, other.id)
    if (!source || !target || !otherTarget) {
      throw new Error("Failed to create home existing title-link test threads")
    }

    await testUtils.addParticipant(source.id, user.id)
    await testUtils.addParticipant(target.id, user.id)
    await testUtils.addParticipant(otherTarget.id, other.id)

    const sent = await sendMessage(
      {
        peerId: { type: { oneofKind: "chat", chat: { chatId: BigInt(source.id) } } },
        message: "see Personal",
        entities: threadTitleEntities({ spaceId: 0, title: "Personal", offset: 4, length: 8 }),
      },
      testUtils.functionContext({ userId: user.id, sessionId: 1 }),
    )

    const message = extractNewMessage(sent)
    expect(message).toBeTruthy()
    expect(messageThreadTarget(message)).toBe(BigInt(target.id))
    expect(messageThreadTarget(message)).not.toBe(BigInt(otherTarget.id))

    await expectGraphLink({
      fromChatId: source.id,
      fromMessageId: Number(message?.id),
      toChatId: target.id,
      scopeType: "user",
      scopeId: user.id,
    })
  })

  test("ignores explicit thread entities when the sender cannot access the target chat", async () => {
    const { space, users } = await testUtils.createSpaceWithMembers("Graph Inaccessible Target", [
      "graph-inaccessible-sender@example.com",
      "graph-inaccessible-owner@example.com",
    ])
    const sender = users[0]!
    const targetOwner = users[1]!
    const source = await testUtils.createChat(space.id, "Visible Source", "thread", true, sender.id)
    const target = await testUtils.createChat(space.id, "Private Target", "thread", false, targetOwner.id)
    if (!source || !target) {
      throw new Error("Failed to create inaccessible-target test threads")
    }

    await testUtils.addParticipant(target.id, targetOwner.id)

    const sent = await sendMessage(
      {
        peerId: { type: { oneofKind: "chat", chat: { chatId: BigInt(source.id) } } },
        message: "see private",
        entities: {
          entities: [
            {
              type: MessageEntity_Type.THREAD,
              offset: 4n,
              length: 7n,
              entity: {
                oneofKind: "thread",
                thread: { chatId: BigInt(target.id) },
              },
            },
          ],
        },
      },
      testUtils.functionContext({ userId: sender.id, sessionId: 1 }),
    )

    const message = extractNewMessage(sent)
    expect(message).toBeTruthy()

    await sleep(50)

    const links = await db
      .select()
      .from(schema.threadGraphLinks)
      .where(
        and(
          eq(schema.threadGraphLinks.kind, "thread_link"),
          eq(schema.threadGraphLinks.fromChatId, source.id),
          eq(schema.threadGraphLinks.fromMessageId, Number(message?.id)),
          eq(schema.threadGraphLinks.toChatId, target.id),
          isNull(schema.threadGraphLinks.deletedAt),
        ),
      )
    expect(links).toHaveLength(0)

    const targetMessages = await db
      .select({ id: schema.messages.globalId })
      .from(schema.messages)
      .where(eq(schema.messages.chatId, target.id))
    expect(targetMessages).toHaveLength(0)
  })
})

function threadTitleEntities(input: {
  spaceId: number
  title: string
  offset: number
  length: number
}): MessageEntities {
  return {
    entities: [
      {
        type: MessageEntity_Type.THREAD_TITLE,
        offset: BigInt(input.offset),
        length: BigInt(input.length),
        entity: {
          oneofKind: "threadTitle",
          threadTitle: {
            spaceId: BigInt(input.spaceId),
            title: input.title,
          },
        },
      },
    ],
  }
}

function extractNewMessage(result: Awaited<ReturnType<typeof sendMessage>>): Message | undefined {
  for (const update of result.updates) {
    if (update.update.oneofKind === "newMessage") {
      return update.update.newMessage?.message
    }
  }

  return undefined
}

function messageThreadTarget(message: Message | undefined): bigint | undefined {
  const entity = message?.entities?.entities[0]
  if (entity?.type !== MessageEntity_Type.THREAD || entity.entity.oneofKind !== "thread") {
    return undefined
  }

  return entity.entity.thread.chatId
}

async function expectGraphLink(input: {
  fromChatId: number
  fromMessageId: number
  toChatId: number
  scopeType?: "space" | "user"
  scopeId: number
}): Promise<void> {
  for (let attempt = 0; attempt < 20; attempt += 1) {
    const links = await db
      .select()
      .from(schema.threadGraphLinks)
      .where(
        and(
          eq(schema.threadGraphLinks.kind, "thread_link"),
          eq(schema.threadGraphLinks.fromChatId, input.fromChatId),
          eq(schema.threadGraphLinks.fromMessageId, input.fromMessageId),
          eq(schema.threadGraphLinks.toChatId, input.toChatId),
          isNull(schema.threadGraphLinks.deletedAt),
        ),
      )

    if (links.length === 1 && links[0]?.backlinkMessageGlobalId !== null) {
      expect(links[0]).toMatchObject({
        scopeType: input.scopeType ?? "space",
        scopeId: input.scopeId,
        entityIndex: 0,
      })
      return
    }

    await sleep(10)
  }

  throw new Error(`Expected graph link ${input.fromChatId}:${input.fromMessageId} -> ${input.toChatId}`)
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms))
}
