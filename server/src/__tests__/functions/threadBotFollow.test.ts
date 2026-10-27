import { afterAll, beforeAll, describe, expect, mock, spyOn, test } from "bun:test"
import { MessageEntity_Type, type MessageEntities } from "@inline-chat/protocol/core"
import { and, eq } from "drizzle-orm"
import { setupTestDatabase, teardownTestDatabase, testUtils } from "../setup"
import { sendMessage } from "@in/server/functions/messages.sendMessage"
import { db } from "@in/server/db"
import { botCommands, chats, dialogs, messages, users, type DbUser } from "@in/server/db/schema"
import { getAddressedUserIds } from "@in/server/modules/threadAutoFollow"
import * as threadTitles from "@in/server/modules/threadTitles"

// Follow state is the contract here; untitled threads would otherwise ask a provider for a title.
mock.module("@in/server/libs/openAI", () => ({ openaiClient: undefined }))
spyOn(threadTitles, "maybeScheduleThreadTitleGeneration").mockImplementation(() => undefined)

const runId = Date.now()
let userIndex = 0
const nextEmail = (label: string) => `${label}-${runId}-${userIndex++}@example.com`

async function createBot(label: string): Promise<DbUser> {
  const user = await testUtils.createUser(nextEmail(label))
  const [bot] = await db.update(users).set({ bot: true }).where(eq(users.id, user.id)).returning()
  return bot!
}

async function createThread(members: DbUser[]) {
  const chat = await testUtils.createChat(null, "Bot follow thread", "thread", false, members[0]!.id)
  if (!chat) throw new Error("Thread chat not created")
  for (const member of members) await testUtils.addParticipant(chat.id, member.id)
  return chat
}

function mentions(...items: { userId: number; offset: number; length: number }[]): MessageEntities {
  return {
    entities: items.map((item) => ({
      type: MessageEntity_Type.MENTION,
      offset: BigInt(item.offset),
      length: BigInt(item.length),
      entity: { oneofKind: "mention" as const, mention: { userId: BigInt(item.userId) } },
    })),
  }
}

function command(text: string, botUserId: number): MessageEntities {
  return {
    entities: [
      {
        type: MessageEntity_Type.BOT_COMMAND,
        offset: 0n,
        length: BigInt(text.length),
        entity: { oneofKind: "botCommand", botCommand: { botUserId: BigInt(botUserId) } },
      },
    ],
  }
}

async function send(fromId: number, chatId: number, message: string, entities?: MessageEntities, isBot?: boolean) {
  await sendMessage(
    {
      peerId: { type: { oneofKind: "chat", chat: { chatId: BigInt(chatId) } } },
      message,
      ...(entities ? { entities } : {}),
    },
    { ...testUtils.functionContext({ userId: fromId, sessionId: 1 }), ...(isBot !== undefined ? { isBot } : {}) },
  )
}

async function followMode(chatId: number, userId: number) {
  const [dialog] = await db
    .select()
    .from(dialogs)
    .where(and(eq(dialogs.chatId, chatId), eq(dialogs.userId, userId)))
    .limit(1)
  return dialog?.followMode ?? null
}

describe("bots enter a thread through its opening message", () => {
  let owner: DbUser
  let alice: DbUser
  let scout: DbUser
  let chief: DbUser

  beforeAll(async () => {
    await setupTestDatabase()
    owner = await testUtils.createUser(nextEmail("owner"))
    alice = await testUtils.createUser(nextEmail("alice"))
    scout = await createBot("scout")
    chief = await createBot("chief")
  })
  afterAll(teardownTestDatabase)

  test("a bot replying early in a fresh thread does not start following", async () => {
    const chat = await createThread([owner, alice, scout])
    await send(owner.id, chat.id, "hi everyone")
    await send(scout.id, chat.id, "hello")

    expect(await followMode(chat.id, scout.id)).toBeNull()
    expect(await followMode(chat.id, owner.id)).toBe("following")
  })

  test("the bot the opening message mentions follows", async () => {
    const chat = await createThread([owner, scout])
    await send(owner.id, chat.id, "@scout find flights", mentions({ userId: scout.id, offset: 0, length: 6 }))

    expect(await followMode(chat.id, scout.id)).toBe("following")
    expect(await followMode(chat.id, owner.id)).toBe("following")
  })

  test("a bot mentioned after the opening message answers once without following", async () => {
    const chat = await createThread([owner, chief, scout])
    await send(owner.id, chat.id, "@chief plan the launch", mentions({ userId: chief.id, offset: 0, length: 6 }))
    await send(owner.id, chat.id, "@scout what's churn?", mentions({ userId: scout.id, offset: 0, length: 6 }))

    expect(await followMode(chat.id, chief.id)).toBe("following")
    expect(await followMode(chat.id, scout.id)).toBeNull()
  })

  test("an opener that starts with a person keeps later-mentioned bots out", async () => {
    const chat = await createThread([owner, alice, scout])
    await send(
      owner.id,
      chat.id,
      "@alice ask @scout",
      mentions({ userId: alice.id, offset: 0, length: 6 }, { userId: scout.id, offset: 11, length: 6 }),
    )

    expect(await followMode(chat.id, scout.id)).toBeNull()
  })

  test("an opener addressing two bots makes both follow", async () => {
    const chat = await createThread([owner, chief, scout])
    await send(
      owner.id,
      chat.id,
      "@chief @scout compare vendors",
      mentions({ userId: chief.id, offset: 0, length: 6 }, { userId: scout.id, offset: 7, length: 6 }),
    )

    expect(await followMode(chat.id, chief.id)).toBe("following")
    expect(await followMode(chat.id, scout.id)).toBe("following")
  })

  test("a bot opening a task for another bot assigns it, not itself", async () => {
    const chat = await createThread([owner, chief, scout])
    await send(chief.id, chat.id, "@scout pull last week's signups", mentions({ userId: scout.id, offset: 0, length: 6 }))

    expect(await followMode(chat.id, scout.id)).toBe("following")
    expect(await followMode(chat.id, chief.id)).toBeNull()
  })

  test("a bot's unaddressed opener makes that bot follow its own thread", async () => {
    const chat = await createThread([owner, chief])
    await send(chief.id, chat.id, "Daily report")

    expect(await followMode(chat.id, chief.id)).toBe("following")
  })

  test("explicit unfollow survives being addressed by an opener", async () => {
    const chat = await createThread([owner, scout])
    await db.insert(dialogs).values({ chatId: chat.id, userId: scout.id, followMode: "unfollowed" })
    await send(owner.id, chat.id, "@scout find flights", mentions({ userId: scout.id, offset: 0, length: 6 }))

    expect(await followMode(chat.id, scout.id)).toBe("unfollowed")
  })

  async function createReplyThreadOn(anchorAuthor: DbUser) {
    const parent = await createThread([owner, alice, scout, chief])
    await db.insert(messages).values({ chatId: parent.id, messageId: 1, fromId: anchorAuthor.id, text: "anchor" })
    const [child] = await db
      .insert(chats)
      .values({ type: "thread", title: null, publicThread: false, createdBy: owner.id, parentChatId: parent.id, parentMessageId: 1 })
      .returning()
    if (!child) throw new Error("Reply thread not created")
    return child
  }

  test("a reply thread on a bot's message with no mention assigns that bot", async () => {
    const child = await createReplyThreadOn(chief)
    await send(owner.id, child.id, "go on")

    expect(await followMode(child.id, chief.id)).toBe("following")
    expect(await followMode(child.id, owner.id)).toBe("following")
  })

  test("a reply thread opener addressed to a person leaves the anchor bot out", async () => {
    const child = await createReplyThreadOn(chief)
    await send(owner.id, child.id, "@alice thoughts?", mentions({ userId: alice.id, offset: 0, length: 6 }))

    expect(await followMode(child.id, chief.id)).toBeNull()
  })

  test("later messages in a reply thread do not pull in the anchor bot", async () => {
    const child = await createReplyThreadOn(chief)
    await send(owner.id, child.id, "@alice thoughts?", mentions({ userId: alice.id, offset: 0, length: 6 }))
    await send(alice.id, child.id, "looks fine")

    expect(await followMode(child.id, chief.id)).toBeNull()
    expect(await followMode(child.id, alice.id)).toBe("following")
  })

  test("a bot answering in a reply thread on a person's message follows it and keeps that person in", async () => {
    const child = await createReplyThreadOn(alice)
    await send(scout.id, child.id, "Here's what I found")

    expect(await followMode(child.id, scout.id)).toBe("following")
    expect(await followMode(child.id, alice.id)).toBe("following")
  })

  test("a thread only you and one bot can see assigns that bot, like a DM", async () => {
    const chat = await createThread([owner, scout])
    await send(owner.id, chat.id, "find flights to Tokyo")

    expect(await followMode(chat.id, scout.id)).toBe("following")
  })

  test("an unaddressed opener in a thread with other people assigns no bot", async () => {
    const chat = await createThread([owner, alice, scout])
    await send(owner.id, chat.id, "find flights to Tokyo")

    expect(await followMode(chat.id, scout.id)).toBeNull()
  })

  test("a system message before the first message does not hide the opener", async () => {
    const chat = await createThread([owner, scout])
    await db.insert(messages).values({
      chatId: chat.id,
      messageId: 1,
      fromId: alice.id,
      systemMessageEncrypted: Buffer.from("backlink"),
      systemMessageIv: Buffer.from("iv"),
      systemMessageTag: Buffer.from("tag"),
    })
    await db.update(chats).set({ lastMsgId: 1 }).where(eq(chats.id, chat.id))
    await send(owner.id, chat.id, "@scout find flights", mentions({ userId: scout.id, offset: 0, length: 6 }))

    expect(await followMode(chat.id, scout.id)).toBe("following")
  })

  test("many system messages before the first message don't hide the opener", async () => {
    const chat = await createThread([owner, scout])
    await db.insert(messages).values(
      Array.from({ length: 16 }, (_, index) => ({
        chatId: chat.id,
        messageId: index + 1,
        fromId: alice.id,
        systemMessageEncrypted: Buffer.from("pin"),
        systemMessageIv: Buffer.from("iv"),
        systemMessageTag: Buffer.from("tag"),
      })),
    )
    await db.update(chats).set({ lastMsgId: 16, messageIdCounter: 16 }).where(eq(chats.id, chat.id))
    await send(owner.id, chat.id, "@scout find flights", mentions({ userId: scout.id, offset: 0, length: 6 }))

    expect(await followMode(chat.id, scout.id)).toBe("following")
  })

  test("deleting the opener doesn't make a later mention the opener", async () => {
    const chat = await createThread([owner, alice, scout])
    await send(owner.id, chat.id, "kickoff notes")
    await db.update(chats).set({ lastMsgId: null }).where(eq(chats.id, chat.id))
    await db.delete(messages).where(eq(messages.chatId, chat.id))
    await send(owner.id, chat.id, "@scout what's churn?", mentions({ userId: scout.id, offset: 0, length: 6 }))

    expect(await followMode(chat.id, scout.id)).toBeNull()
  })

  test("chats from before the opener flag existed never assign bots again", async () => {
    const chat = await createThread([owner, scout])
    await db.update(chats).set({ conversationStarted: true }).where(eq(chats.id, chat.id))
    await send(owner.id, chat.id, "@scout find flights", mentions({ userId: scout.id, offset: 0, length: 6 }))

    expect(await followMode(chat.id, scout.id)).toBeNull()
  })

  test("an @username typed without a client entity still addresses the bot", async () => {
    await db.update(users).set({ username: `scout${runId}` }).where(eq(users.id, scout.id))
    const chat = await createThread([owner, alice, scout])
    await send(owner.id, chat.id, `@scout${runId} find flights`)

    expect(await followMode(chat.id, scout.id)).toBe("following")
  })

  test("the authenticated bot flag gives the same result as looking the sender up", async () => {
    const chat = await createThread([owner, alice, scout])
    await send(owner.id, chat.id, "hi everyone", undefined, false)
    await send(scout.id, chat.id, "hello", undefined, true)
    expect(await followMode(chat.id, scout.id)).toBeNull()

    const task = await createThread([owner, chief])
    await send(chief.id, task.id, "Daily report", undefined, true)
    expect(await followMode(task.id, chief.id)).toBe("following")
  })

  test("a thread under a bot DM assigns the DM's bot", async () => {
    const dm = await testUtils.createPrivateChat(owner, scout)
    if (!dm) throw new Error("DM not created")
    const [child] = await db
      .insert(chats)
      .values({ type: "thread", title: null, publicThread: false, createdBy: owner.id, parentChatId: dm.id })
      .returning()
    if (!child) throw new Error("DM thread not created")
    await testUtils.addParticipant(child.id, owner.id)
    await testUtils.addParticipant(child.id, scout.id)
    await send(owner.id, child.id, "start a packing list")

    expect(await followMode(child.id, scout.id)).toBe("following")
  })

  test("a command as the first message runs once and assigns no bot", async () => {
    await db.insert(botCommands).values({ botUserId: chief.id, command: "status", description: "Status" }).onConflictDoNothing()
    const chat = await createThread([owner, alice, chief, scout])
    await send(owner.id, chat.id, "/status", command("/status", chief.id))

    expect(await followMode(chat.id, chief.id)).toBeNull()
    expect(await followMode(chat.id, owner.id)).toBe("following")
  })

  test("the first ordinary message after a command decides who follows", async () => {
    await db.insert(botCommands).values({ botUserId: chief.id, command: "status", description: "Status" }).onConflictDoNothing()
    const chat = await createThread([owner, alice, chief, scout])
    await send(owner.id, chat.id, "/status", command("/status", chief.id))
    await send(owner.id, chat.id, "@scout find flights", mentions({ userId: scout.id, offset: 0, length: 6 }))

    expect(await followMode(chat.id, scout.id)).toBe("following")
    expect(await followMode(chat.id, chief.id)).toBeNull()
  })

  test("in a thread with one bot, a command doesn't assign it but the next message does", async () => {
    await db.insert(botCommands).values({ botUserId: chief.id, command: "status", description: "Status" }).onConflictDoNothing()
    const chat = await createThread([owner, chief])
    await send(owner.id, chat.id, "/status", command("/status", chief.id))
    expect(await followMode(chat.id, chief.id)).toBeNull()

    await send(owner.id, chat.id, "and the open tickets?")
    expect(await followMode(chat.id, chief.id)).toBe("following")
  })
})

describe("getAddressedUserIds", () => {
  test("a leading run of mentions decides", () => {
    const run = mentions({ userId: 1, offset: 0, length: 2 }, { userId: 2, offset: 4, length: 2 }, { userId: 3, offset: 12, length: 2 })
    expect([...getAddressedUserIds("@a, @b compare @c", run)]).toEqual([1, 2])
  })

  test("without a leading mention, every mention counts", () => {
    expect([...getAddressedUserIds("hey @a", mentions({ userId: 1, offset: 4, length: 2 }))]).toEqual([1])
  })

  test("leading whitespace still counts as leading", () => {
    expect([...getAddressedUserIds("  @a hi", mentions({ userId: 1, offset: 2, length: 2 }))]).toEqual([1])
  })

  test("a bot command target is not addressed for following", () => {
    const entities: MessageEntities = {
      entities: [
        {
          type: MessageEntity_Type.BOT_COMMAND,
          offset: 0n,
          length: 11n,
          entity: { oneofKind: "botCommand", botCommand: { botUserId: 9n } },
        },
      ],
    }
    expect([...getAddressedUserIds("/help@scout", entities)]).toEqual([])
  })
})
