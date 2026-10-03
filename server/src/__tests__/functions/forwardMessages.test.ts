import { beforeEach, describe, expect, spyOn, test } from "bun:test"
import { InputPeer, MessageActions, MessageEntity_Type, Photo_Format } from "@inline-chat/protocol/core"
import { db } from "@in/server/db"
import { blockContents, chatParticipants, chats, externalTasks, files, members, messageAttachments, messages, messageSubmissions, photos, subthreadParentMessages, updates, voices } from "@in/server/db/schema"
import type { DbUser } from "@in/server/db/schema"
import { FileModel } from "@in/server/db/models/files"
import { sendMessage } from "@in/server/functions/messages.sendMessage"
import { deleteMessage } from "@in/server/functions/messages.deleteMessage"
import { deleteChat } from "@in/server/functions/messages.deleteChat"
import { getChatHistory } from "@in/server/functions/messages.getChatHistory"
import { getMessages } from "@in/server/functions/messages.getMessages"
import { AccessGuards } from "@in/server/modules/authorization/accessGuards"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { MessageModel } from "@in/server/db/models/messages"
import { editMessage } from "@in/server/functions/messages.editMessage"
import { forwardMessages } from "@in/server/functions/messages.forwardMessages"
import { encrypt, encryptBinary } from "@in/server/modules/encryption/encryption"
import { encryptStoredBlockContent } from "@in/server/modules/message/blockContentPayload"
import { and, asc, eq, sql } from "drizzle-orm"
import { setupTestLifecycle, testUtils } from "../setup"

const runId = Date.now()
let userIndex = 0
const nextEmail = (label: string) => `${label}-${runId}-${userIndex++}@example.com`

setupTestLifecycle()

type Scenario = {
  currentUser: DbUser
  dmPeerUser: DbUser
  sourceChatId: number
  destinationThreadId: number
  sourceMessageId: bigint
  fromPeerId: InputPeer
  toPeerId: InputPeer
}

const createScenario = async ({ sourceFromCurrentUser }: { sourceFromCurrentUser: boolean }): Promise<Scenario> => {
  const currentUser = await testUtils.createUser(nextEmail("current"))
  const dmPeerUser = await testUtils.createUser(nextEmail("dm-peer"))
  const destinationPeerUser = await testUtils.createUser(nextEmail("thread-peer"))
  const space = await testUtils.createSpace("Forward Test Space")
  if (!space) {
    throw new Error("Failed to create test space")
  }

  await db.insert(members).values([
    { userId: currentUser.id, spaceId: space.id, role: "member" },
    { userId: destinationPeerUser.id, spaceId: space.id, role: "member" },
  ])

  const [destinationThread] = await db
    .insert(chats)
    .values({
      type: "thread",
      title: "Private Thread",
      spaceId: space.id,
      publicThread: false,
      createdBy: currentUser.id,
    })
    .returning()
  if (!destinationThread) {
    throw new Error("Failed to create destination thread")
  }

  await db.insert(chatParticipants).values([
    { chatId: destinationThread.id, userId: currentUser.id },
    { chatId: destinationThread.id, userId: destinationPeerUser.id },
  ])

  const sourceDm = await testUtils.createPrivateChat(currentUser, dmPeerUser)
  if (!sourceDm) {
    throw new Error("Failed to create source DM")
  }

  const sourceMessage = await testUtils.createTestMessage({
    messageId: 1,
    chatId: sourceDm.id,
    fromId: sourceFromCurrentUser ? currentUser.id : dmPeerUser.id,
    text: "forward me",
  })

  return {
    currentUser,
    dmPeerUser,
    sourceChatId: sourceDm.id,
    destinationThreadId: destinationThread.id,
    sourceMessageId: BigInt(sourceMessage.messageId),
    fromPeerId: {
      type: { oneofKind: "user", user: { userId: BigInt(dmPeerUser.id) } },
    },
    toPeerId: {
      type: { oneofKind: "chat", chat: { chatId: BigInt(destinationThread.id) } },
    },
  }
}

const forwardedMessageFromDestination = async (destinationThreadId: number) => {
  const [storedMessage] = await db
    .select()
    .from(messages)
    .where(eq(messages.chatId, destinationThreadId))

  if (!storedMessage) {
    throw new Error("Expected forwarded message to be stored")
  }

  return MessageModel.getMessage(storedMessage.messageId, destinationThreadId)
}

const createVoiceForUser = async (userId: number) => {
  const [file] = await db
    .insert(files)
    .values({
      fileUniqueId: `INV-forward-${runId}-${userIndex++}`,
      userId,
      fileType: "voice",
      mimeType: "audio/ogg",
      fileSize: 222,
    })
    .returning()

  if (!file) {
    throw new Error("Failed to create test voice file")
  }

  const [voice] = await db
    .insert(voices)
    .values({
      fileId: file.id,
      duration: 9,
      waveform: Buffer.from([8, 6, 7, 5]),
    })
    .returning()

  if (!voice) {
    throw new Error("Failed to create test voice")
  }

  return voice
}

describe("forwardMessages DM -> private thread", () => {
  beforeEach(() => {
    userIndex = 0
  })

  test("forwards incoming DM message to a private thread", async () => {
    const scenario = await createScenario({ sourceFromCurrentUser: false })
    const context = testUtils.functionContext({ userId: scenario.currentUser.id, sessionId: 1 })

    const result = await forwardMessages(
      {
        fromPeerId: scenario.fromPeerId,
        toPeerId: scenario.toPeerId,
        messageIds: [scenario.sourceMessageId],
      },
      context,
    )

    expect(result.updates.length).toBeGreaterThan(0)

    const forwarded = await forwardedMessageFromDestination(scenario.destinationThreadId)
    expect(forwarded.text).toBe("forward me")
    expect(forwarded.fwdFromPeerUserId).toBe(scenario.dmPeerUser.id)
    expect(forwarded.fwdFromSenderId).toBe(scenario.dmPeerUser.id)
    expect(forwarded.fwdFromMessageId).toBe(Number(scenario.sourceMessageId))
  })

  test("forwards outgoing DM message to a private thread", async () => {
    const scenario = await createScenario({ sourceFromCurrentUser: true })
    const context = testUtils.functionContext({ userId: scenario.currentUser.id, sessionId: 1 })

    const result = await forwardMessages(
      {
        fromPeerId: scenario.fromPeerId,
        toPeerId: scenario.toPeerId,
        messageIds: [scenario.sourceMessageId],
      },
      context,
    )

    expect(result.updates.length).toBeGreaterThan(0)

    const forwarded = await forwardedMessageFromDestination(scenario.destinationThreadId)
    expect(forwarded.text).toBe("forward me")
    expect(forwarded.fwdFromPeerUserId).toBeNull()
    expect(forwarded.fwdFromPeerChatId).toBeNull()
    expect(forwarded.fwdFromSenderId).toBeNull()
    expect(forwarded.fwdFromMessageId).toBeNull()
  })

  test("forwards voice media and clones the voice row", async () => {
    const scenario = await createScenario({ sourceFromCurrentUser: false })
    const voice = await createVoiceForUser(scenario.dmPeerUser.id)
    const [sourceVoiceMessage] = await db
      .insert(messages)
      .values({
        messageId: 2,
        chatId: scenario.sourceChatId,
        fromId: scenario.dmPeerUser.id,
        mediaType: "voice",
        voiceId: voice.id,
      })
      .returning()

    if (!sourceVoiceMessage) {
      throw new Error("Failed to create source voice message")
    }

    const context = testUtils.functionContext({ userId: scenario.currentUser.id, sessionId: 1 })

    const result = await forwardMessages(
      {
        fromPeerId: scenario.fromPeerId,
        toPeerId: scenario.toPeerId,
        messageIds: [BigInt(sourceVoiceMessage.messageId)],
      },
      context,
    )

    expect(result.updates.length).toBeGreaterThan(0)

    const forwarded = await forwardedMessageFromDestination(scenario.destinationThreadId)
    expect(forwarded.voiceId).not.toBeNull()
    expect(forwarded.voice?.id).not.toBe(voice.id)
    expect(forwarded.voice?.duration).toBe(9)
    expect(forwarded.voice?.waveform).toEqual(Buffer.from([8, 6, 7, 5]))
    expect(forwarded.fwdFromPeerUserId).toBe(scenario.dmPeerUser.id)
  })

  test("preserves structural rich content", async () => {
    const scenario = await createScenario({ sourceFromCurrentUser: true })
    const context = testUtils.functionContext({ userId: scenario.currentUser.id, sessionId: 1 })
    await editMessage(
      {
        peer: scenario.fromPeerId,
        messageId: scenario.sourceMessageId,
        text: "# Forwarded heading",
        parseMarkdown: true,
      },
      context,
    )

    await forwardMessages(
      {
        fromPeerId: scenario.fromPeerId,
        toPeerId: scenario.toPeerId,
        messageIds: [scenario.sourceMessageId],
      },
      context,
    )

    const forwarded = await forwardedMessageFromDestination(scenario.destinationThreadId)
    expect(forwarded.text).toBe("# Forwarded heading")
    expect(forwarded.blockContent?.blocks[0]?.kind.oneofKind).toBe("heading")
  })
})


describe("retry-safe forwarding submissions", () => {
  const request = (scenario: Scenario, randomId = 201n) => ({
    fromPeerId: scenario.fromPeerId,
    toPeerId: scenario.toPeerId,
    messageIds: [scenario.sourceMessageId],
    submissions: [{ randomId, expectedSourceRevision: 0n }],
    shareForwardHeader: false,
  })
  const destinationRows = (scenario: Scenario) => db.select().from(messages)
    .where(eq(messages.chatId, scenario.destinationThreadId)).orderBy(asc(messages.messageId))

  test("a historical nudge carries its visible label as ordinary text", async () => {
    const scenario = await createScenario({ sourceFromCurrentUser: true })
    const context = testUtils.functionContext({ userId: scenario.currentUser.id })
    await db.update(messages).set({ mediaType: "nudge" }).where(and(
      eq(messages.chatId, scenario.sourceChatId), eq(messages.messageId, 1),
    ))
    const captured = (await getMessages({ peerId: scenario.fromPeerId, messageIds: [1n] }, context)).messages[0]!
    await forwardMessages({ ...request(scenario), submissions: [{ randomId: 200n,
      expectedSourceRevision: captured.rev!, expectedSourceSnapshot: captured.sourceSnapshot }] }, context)
    const copied = await forwardedMessageFromDestination(scenario.destinationThreadId)
    expect(copied.text).toBe(`forward me\n\n👋 Nudge\n\nSource: inline://chat/${scenario.sourceChatId}?message_id=1`)
    expect(copied.mediaType).toBeNull()
    const history = await getChatHistory({ peerId: scenario.toPeerId }, context)
    expect(history.messages[0]?.isForwarded).toBe(true)
    expect(history.messages[0]?.media).toBeUndefined()
  })

  test("a lost response replays its ordered receipt and original snapshot after source edits", async () => {
    const scenario = await createScenario({ sourceFromCurrentUser: true })
    const context = testUtils.functionContext({ userId: scenario.currentUser.id })
    const input = request(scenario)
    const original = await forwardMessages(input, context)
    await editMessage({ peer: scenario.fromPeerId, messageId: scenario.sourceMessageId, text: "changed later" }, context)
    const retried = await forwardMessages(input, context)
    expect(retried.receipts).toEqual(original.receipts)
    expect(original.receipts).toEqual([{
      sourceMessageId: scenario.sourceMessageId, randomId: 201n, messageId: 1n,
      sourceRevision: 0n, messageDeleted: false,
    }])
    expect(await destinationRows(scenario)).toHaveLength(1)
    const history = await getChatHistory({ peerId: scenario.toPeerId }, context)
    expect(history.messages[0]).toMatchObject({ message: `forward me\n\nSource: inline://chat/${scenario.sourceChatId}?message_id=1`, isForwarded: true })
    expect(history.messages[0]?.fwdFrom).toBeUndefined()
  })

  test("new submissions reject a changed source revision before clone/message effects", async () => {
    const scenario = await createScenario({ sourceFromCurrentUser: true })
    const context = testUtils.functionContext({ userId: scenario.currentUser.id })
    await editMessage({ peer: scenario.fromPeerId, messageId: scenario.sourceMessageId, text: "changed" }, context)
    await expect(forwardMessages(request(scenario), context)).rejects.toMatchObject({ code: RealtimeRpcError.Code.BAD_REQUEST })
    expect(await destinationRows(scenario)).toHaveLength(0)
    expect(await db.select().from(messageSubmissions)).toHaveLength(0)
  })

  test("a consumed identity rejects changed options, ordering, source and destination", async () => {
    const scenario = await createScenario({ sourceFromCurrentUser: true })
    const context = testUtils.functionContext({ userId: scenario.currentUser.id })
    const input = request(scenario)
    await forwardMessages(input, context)
    for (const changed of [
      { ...input, shareForwardHeader: true },
      { ...input, messageIds: [2n] },
      { ...input, toPeerId: scenario.fromPeerId },
      { ...input, messageIds: [1n, 2n], submissions: [...input.submissions, { randomId: 202n, expectedSourceRevision: 0n }] },
    ]) {
      await expect(forwardMessages(changed, context)).rejects.toMatchObject({ code: RealtimeRpcError.Code.BAD_REQUEST })
    }
    expect(await destinationRows(scenario)).toHaveLength(1)
  })

  test("concurrent retries clone one media snapshot and create one message/replay update", async () => {
    const scenario = await createScenario({ sourceFromCurrentUser: true })
    const voice = await createVoiceForUser(scenario.currentUser.id)
    await db.update(messages).set({ mediaType: "voice", voiceId: voice.id }).where(and(
      eq(messages.chatId, scenario.sourceChatId), eq(messages.messageId, 1),
    ))
    const context = testUtils.functionContext({ userId: scenario.currentUser.id })
    const cloneEntered = Promise.withResolvers<void>()
    const releaseClone = Promise.withResolvers<void>()
    const clone = FileModel.cloneVoiceById
    const spy = spyOn(FileModel, "cloneVoiceById").mockImplementation(async (...args) => {
      cloneEntered.resolve()
      await releaseClone.promise
      return clone(...args)
    })
    const attempts: Promise<Awaited<ReturnType<typeof forwardMessages>>>[] = []
    try {
      attempts.push(forwardMessages(request(scenario), context))
      await cloneEntered.promise
      attempts.push(...Array.from({ length: 4 }, () => forwardMessages(request(scenario), context)))
      releaseClone.resolve()
      const settled = await Promise.allSettled(attempts)
      expect(settled.map((result) => result.status)).toEqual(Array(5).fill("fulfilled"))
      const results = settled.flatMap((result) => result.status === "fulfilled" ? [result.value] : [])
      expect(new Set(results.map((result) => result.receipts[0]?.messageId))).toEqual(new Set([1n]))
      expect(await destinationRows(scenario)).toHaveLength(1)
      expect(await db.select().from(voices)).toHaveLength(2)
      expect(await db.select().from(files)).toHaveLength(2)
      expect(await db.select().from(updates).where(eq(updates.entityId, scenario.destinationThreadId))).toHaveLength(1)
      expect(await db.select().from(messageSubmissions)).toHaveLength(1)
      expect(spy).toHaveBeenCalledTimes(1)
    } finally {
      releaseClone.resolve()
      await Promise.allSettled(attempts)
      spy.mockRestore()
    }
  })

  test("a partial media failure rolls back clones and retry completes the same ordered batch", async () => {
    const scenario = await createScenario({ sourceFromCurrentUser: true })
    const voice = await createVoiceForUser(scenario.currentUser.id)
    await db.insert(messages).values({
      messageId: 2, chatId: scenario.sourceChatId, fromId: scenario.currentUser.id,
      mediaType: "voice", voiceId: voice.id,
    })
    const context = testUtils.functionContext({ userId: scenario.currentUser.id })
    const input = { ...request(scenario), messageIds: [1n, 2n], submissions: [
      { randomId: 211n, expectedSourceRevision: 0n }, { randomId: 212n, expectedSourceRevision: 0n },
    ] }
    const clone = FileModel.cloneVoiceById
    const spy = spyOn(FileModel, "cloneVoiceById").mockImplementation(async (...args) => {
      await clone(...args)
      throw new Error("injected failure after cloned media")
    })
    try {
      await expect(forwardMessages(input, context)).rejects.toThrow("injected failure")
    } finally {
      spy.mockRestore()
    }
    expect(await destinationRows(scenario)).toHaveLength(1)
    expect(await db.select().from(voices)).toHaveLength(1)
    expect(await db.select().from(files)).toHaveLength(1)
    const result = await forwardMessages(input, context)
    expect(result.receipts.map((item) => [item.sourceMessageId, item.messageId])).toEqual([[1n, 1n], [2n, 2n]])
    expect(await destinationRows(scenario)).toHaveLength(2)
    expect(await db.select().from(voices)).toHaveLength(2)
    expect(await db.select().from(files)).toHaveLength(2)
  })

  test("an ordinary send winning a concurrent identity collision rolls back forwarded media in another destination", async () => {
    const scenario = await createScenario({ sourceFromCurrentUser: true })
    const [destination] = await db.select().from(chats).where(eq(chats.id, scenario.destinationThreadId))
    if (!destination) throw new Error("missing destination")
    const other = await testUtils.createChat(destination.spaceId, "Other destination", "thread", true, scenario.currentUser.id)
    if (!other) throw new Error("missing other destination")
    const voice = await createVoiceForUser(scenario.currentUser.id)
    await db.update(messages).set({ mediaType: "voice", voiceId: voice.id }).where(eq(messages.chatId, scenario.sourceChatId))
    const context = testUtils.functionContext({ userId: scenario.currentUser.id })
    const cloneEntered = Promise.withResolvers<void>()
    const releaseClone = Promise.withResolvers<void>()
    const clone = FileModel.cloneVoiceById
    const spy = spyOn(FileModel, "cloneVoiceById").mockImplementation(async (...args) => {
      cloneEntered.resolve()
      await releaseClone.promise
      return clone(...args)
    })
    const attempt = forwardMessages(request(scenario, 271n), context)
    try {
      await cloneEntered.promise
      await sendMessage({ peerId: { type: { oneofKind: "chat", chat: { chatId: BigInt(other.id) } } },
        message: "ordinary winner", randomId: 271n }, context)
      releaseClone.resolve()
      await expect(attempt).rejects.toMatchObject({ code: RealtimeRpcError.Code.BAD_REQUEST })
      expect(await destinationRows(scenario)).toHaveLength(0)
      expect(await db.select().from(voices)).toHaveLength(1)
      expect(await db.select().from(files)).toHaveLength(1)
      expect(await db.select().from(messageSubmissions)).toHaveLength(1)
      expect(await db.select().from(messages).where(eq(messages.chatId, other.id))).toHaveLength(1)
    } finally {
      releaseClone.resolve()
      await Promise.allSettled([attempt])
      spy.mockRestore()
    }
  })

  test("ordinary sends and forwarding reject shared identities in both directions after deletion", async () => {
    const scenario = await createScenario({ sourceFromCurrentUser: true })
    const context = testUtils.functionContext({ userId: scenario.currentUser.id })
    await sendMessage({ peerId: scenario.toPeerId, message: "ordinary", randomId: 221n }, context)
    await deleteMessage({ peer: scenario.toPeerId, messageIds: [1n] }, context)
    await expect(forwardMessages(request(scenario, 221n), context)).rejects.toMatchObject({ code: RealtimeRpcError.Code.BAD_REQUEST })
    await forwardMessages(request(scenario, 222n), context)
    await deleteMessage({ peer: scenario.toPeerId, messageIds: [2n] }, context)
    await expect(sendMessage({ peerId: scenario.toPeerId, message: "ordinary", randomId: 222n }, context))
      .rejects.toMatchObject({ code: RealtimeRpcError.Code.BAD_REQUEST })
    expect(await destinationRows(scenario)).toHaveLength(0)
    const retried = await forwardMessages(request(scenario, 222n), context)
    expect(retried.receipts[0]).toMatchObject({ messageId: 2n, messageDeleted: true })
    expect(await destinationRows(scenario)).toHaveLength(0)
  })

  test("a committed source deletion still returns the original receipt", async () => {
    const scenario = await createScenario({ sourceFromCurrentUser: true })
    const context = testUtils.functionContext({ userId: scenario.currentUser.id })
    const original = await forwardMessages(request(scenario), context)
    await deleteMessage({ peer: scenario.fromPeerId, messageIds: [1n] }, context)
    expect((await forwardMessages(request(scenario), context)).receipts).toEqual(original.receipts)
    expect(await destinationRows(scenario)).toHaveLength(1)
  })

  test("a committed retry blocked on its identity rechecks access after concurrent removal", async () => {
    const scenario = await createScenario({ sourceFromCurrentUser: true })
    const context = testUtils.functionContext({ userId: scenario.currentUser.id })
    const input = request(scenario, 281n)
    await forwardMessages(input, context)
    const locked = Promise.withResolvers<number>()
    const release = Promise.withResolvers<void>()
    const blocker = db.transaction(async (tx) => {
      await tx.execute(sql`select pg_advisory_xact_lock(hashtextextended(${`${scenario.currentUser.id}:281`}, 0))`)
      const rows = await tx.execute(sql`select pg_backend_pid() as pid`)
      locked.resolve(Number(rows[0]!["pid"]))
      await release.promise
    })
    let retry: Promise<Awaited<ReturnType<typeof forwardMessages>>> | undefined
    try {
      const blockerPid = await Promise.race([locked.promise, blocker.then(() => { throw new Error("lock released too early") })])
      retry = forwardMessages(input, context)
      const deadline = Date.now() + 5_000
      while (true) {
        const rows = await db.execute(sql`select exists (
          select 1 from pg_stat_activity where ${blockerPid} = any(pg_blocking_pids(pid))
        ) as waiting`)
        if (rows[0]!["waiting"] === true) break
        if (Date.now() >= deadline) throw new Error("retry did not wait on its submission identity")
        await Bun.sleep(5)
      }
      await db.transaction(async (tx) => {
        await tx.select().from(chats).where(eq(chats.id, scenario.destinationThreadId)).for("update")
        await tx.delete(chatParticipants).where(and(
          eq(chatParticipants.chatId, scenario.destinationThreadId), eq(chatParticipants.userId, scenario.currentUser.id),
        ))
      })
      release.resolve()
      await blocker
      await expect(retry).rejects.toMatchObject({ code: RealtimeRpcError.Code.PEER_ID_INVALID })
      expect(await destinationRows(scenario)).toHaveLength(1)
      expect(await db.select().from(messageSubmissions)).toHaveLength(1)
    } finally {
      release.resolve()
      await Promise.allSettled([blocker, ...(retry ? [retry] : [])])
    }
  })

  test("revocation that wins an inherited root lock rejects forwarding after preflight without media copies", async () => {
    const scenario = await createScenario({ sourceFromCurrentUser: true })
    const [destination] = await db.select().from(chats).where(eq(chats.id, scenario.destinationThreadId))
    if (!destination) throw new Error("missing destination")
    const [root] = await db.insert(chats).values({ type: "thread", spaceId: destination.spaceId, publicThread: false }).returning()
    if (!root) throw new Error("missing root")
    await db.insert(chatParticipants).values({ chatId: root.id, userId: scenario.currentUser.id })
    const [child] = await db.insert(chats).values({ type: "thread", parentChatId: root.id, publicThread: false }).returning()
    if (!child) throw new Error("missing child")
    const voice = await createVoiceForUser(scenario.currentUser.id)
    await db.insert(messages).values({ messageId: 1, chatId: child.id, fromId: scenario.currentUser.id, mediaType: "voice", voiceId: voice.id })
    const context = testUtils.functionContext({ userId: scenario.currentUser.id })
    const locked = Promise.withResolvers<void>()
    const preflight = Promise.withResolvers<void>()
    const release = Promise.withResolvers<void>()
    const guard = AccessGuards.ensureChatAccess
    const spy = spyOn(AccessGuards, "ensureChatAccess").mockImplementation(async (...args) => {
      await guard(...args)
      if (args[0].id === scenario.destinationThreadId && args[2] === undefined) preflight.resolve()
    })
    const revoke = db.transaction(async (tx) => {
      await tx.select().from(chats).where(eq(chats.id, root.id)).for("update")
      locked.resolve()
      await preflight.promise
      await tx.delete(chatParticipants).where(and(eq(chatParticipants.chatId, root.id), eq(chatParticipants.userId, scenario.currentUser.id)))
      await release.promise
    })
    let attempt: Promise<Awaited<ReturnType<typeof forwardMessages>>> | undefined
    try {
      await Promise.race([locked.promise, revoke])
      attempt = forwardMessages({ ...request(scenario), fromPeerId: { type: { oneofKind: "chat", chat: { chatId: BigInt(child.id) } } } }, context)
      await preflight.promise
      release.resolve()
      await revoke
      await expect(attempt).rejects.toMatchObject({ code: RealtimeRpcError.Code.PEER_ID_INVALID })
      expect(await destinationRows(scenario)).toHaveLength(0)
      expect(await db.select().from(voices)).toHaveLength(1)
      expect(await db.select().from(files)).toHaveLength(1)
      expect(await db.select().from(messageSubmissions)).toHaveLength(0)
    } finally {
      release.resolve()
      await Promise.allSettled([revoke, ...(attempt ? [attempt] : [])])
      spy.mockRestore()
    }
  })

  test("the captured snapshot rejects changed visible cards and retains labels/static links without source actions", async () => {
    const scenario = await createScenario({ sourceFromCurrentUser: true })
    const context = testUtils.functionContext({ userId: scenario.currentUser.id })
    const [source] = await db.select().from(messages).where(eq(messages.chatId, scenario.sourceChatId))
    if (!source) throw new Error("missing source")
    const title = encrypt("Investigate upload failures")
    const [task] = await db.insert(externalTasks).values({
      application: "linear", taskId: "task-1", number: "INL-42", status: "todo", assignedUserId: BigInt(scenario.currentUser.id),
      title: title.encrypted, titleIv: title.iv, titleTag: title.authTag, url: "https://linear.example.test/INL-42",
    }).returning()
    if (!task) throw new Error("missing task")
    await db.insert(messageAttachments).values({ messageId: source.globalId, externalTaskId: BigInt(task.id) })
    const actions = encryptBinary(MessageActions.toBinary({ rows: [{ actions: [
      { actionId: "approve", text: "Approve", action: { oneofKind: "callback", callback: { data: Buffer.from("secret callback") } } },
      { actionId: "copy", text: "Copy reference", action: { oneofKind: "copyText", copyText: { text: "hidden copy value" } } },
    ] }] }))
    await db.update(messages).set({ actionsEncrypted: actions.encrypted, actionsIv: actions.iv, actionsTag: actions.authTag })
      .where(eq(messages.globalId, source.globalId))
    const captured = (await getMessages({ peerId: scenario.fromPeerId, messageIds: [1n] }, context)).messages[0]!
    expect(captured.sourceSnapshot).toMatch(/^[a-f0-9]{64}$/)
    const input = { ...request(scenario), submissions: [{ randomId: 231n, expectedSourceRevision: captured.rev!, expectedSourceSnapshot: captured.sourceSnapshot }] }
    const changed = encrypt("Changed visible title")
    await db.update(externalTasks).set({ title: changed.encrypted, titleIv: changed.iv, titleTag: changed.authTag }).where(eq(externalTasks.id, task.id))
    await expect(forwardMessages(input, context)).rejects.toMatchObject({ code: RealtimeRpcError.Code.BAD_REQUEST })
    expect(await destinationRows(scenario)).toHaveLength(0)
    const refreshed = (await getMessages({ peerId: scenario.fromPeerId, messageIds: [1n] }, context)).messages[0]!
    expect(refreshed.rev).toBe(captured.rev)
    expect(refreshed.sourceSnapshot).not.toBe(captured.sourceSnapshot)
    const result = await forwardMessages({ ...input, submissions: [{ ...input.submissions[0]!, expectedSourceSnapshot: refreshed.sourceSnapshot }] }, context)
    const forwarded = await MessageModel.getMessage(Number(result.receipts[0]!.messageId), scenario.destinationThreadId)
    expect(forwarded.text).toContain("linear · INL-42 · Changed visible title")
    expect(forwarded.text).toContain("Status: To do")
    expect(forwarded.text).toContain("https://linear.example.test/INL-42")
    expect(forwarded.text).toContain("Approve · Copy reference")
    expect(forwarded.text).not.toContain("secret callback")
    expect(forwarded.text).not.toContain("hidden copy value")
    expect(forwarded.actions).toBeNull()
    expect(forwarded.messageAttachments).toHaveLength(0)
    expect(await db.select().from(externalTasks)).toHaveLength(1)
  })

  test("asynchronous image readiness changes invalidate the captured snapshot without an edit revision", async () => {
    const scenario = await createScenario({ sourceFromCurrentUser: true })
    const context = testUtils.functionContext({ userId: scenario.currentUser.id })
    const stored = (readyPhotoId?: bigint) => encryptStoredBlockContent({ text: "forward me", blockContent: { blocks: [{ kind: {
      oneofKind: "image", image: { alt: { offset: 0n, length: 10n }, state: readyPhotoId === undefined
        ? { oneofKind: "pending", pending: {} }
        : { oneofKind: "ready", ready: { id: readyPhotoId, date: 0n, format: Photo_Format.JPEG, sizes: [] } },
      },
    } }] } })
    const pending = stored()
    const [content] = await db.insert(blockContents).values({ payloadEncrypted: pending.encrypted, payloadIv: pending.iv, payloadTag: pending.authTag }).returning()
    if (!content) throw new Error("missing content")
    await db.update(messages).set({ blockContentId: content.id }).where(eq(messages.chatId, scenario.sourceChatId))
    const captured = (await getMessages({ peerId: scenario.fromPeerId, messageIds: [1n] }, context)).messages[0]!
    const [photo] = await db.insert(photos).values({ format: "jpeg" }).returning()
    if (!photo) throw new Error("missing photo")
    const ready = stored(BigInt(photo.id))
    await db.update(blockContents).set({ payloadEncrypted: ready.encrypted, payloadIv: ready.iv, payloadTag: ready.authTag }).where(eq(blockContents.id, content.id))
    const refreshed = (await getMessages({ peerId: scenario.fromPeerId, messageIds: [1n] }, context)).messages[0]!
    expect(refreshed.rev).toBe(captured.rev)
    expect(refreshed.sourceSnapshot).not.toBe(captured.sourceSnapshot)
    await expect(forwardMessages({ ...request(scenario), submissions: [{ randomId: 241n,
      expectedSourceRevision: captured.rev!, expectedSourceSnapshot: captured.sourceSnapshot }] }, context))
      .rejects.toMatchObject({ code: RealtimeRpcError.Code.BAD_REQUEST })
    expect(await destinationRows(scenario)).toHaveLength(0)
    expect(await db.select().from(photos)).toHaveLength(1)
  })

  test("ordinary lost-ack retry after deletion acknowledges identity then deletes the optimistic row", async () => {
    const scenario = await createScenario({ sourceFromCurrentUser: true })
    const context = testUtils.functionContext({ userId: scenario.currentUser.id })
    const input = { peerId: scenario.toPeerId, message: "persisted ordinary intent", randomId: 251n }
    await sendMessage(input, context)
    await deleteMessage({ peer: scenario.toPeerId, messageIds: [1n] }, context)
    const replayed = await sendMessage(input, context)
    expect(replayed.updates.map((update) => update.update.oneofKind)).toEqual(["updateMessageId", "deleteMessages"])
    expect(replayed.updates[1]?.update).toEqual({ oneofKind: "deleteMessages", deleteMessages: {
      peerId: { type: { oneofKind: "chat", chat: { chatId: BigInt(scenario.destinationThreadId) } } }, messageIds: [1n],
    } })
    expect(await destinationRows(scenario)).toHaveLength(0)
    await expect(sendMessage({ ...input, message: "changed intent" }, context)).rejects.toMatchObject({ code: RealtimeRpcError.Code.BAD_REQUEST })
    await db.update(chats).set({ messageIdCounter: 1 }).where(eq(chats.id, scenario.sourceChatId))
    const dmInput = { ...input, peerId: scenario.fromPeerId, randomId: 252n }
    await sendMessage(dmInput, context)
    await deleteMessage({ peer: scenario.fromPeerId, messageIds: [2n] }, context)
    const dmReplay = await sendMessage(dmInput, context)
    expect(dmReplay.updates[1]?.update).toEqual({ oneofKind: "deleteMessages", deleteMessages: {
      peerId: { type: { oneofKind: "user", user: { userId: BigInt(scenario.dmPeerUser.id) } } }, messageIds: [2n],
    } })
  })

  test("deleting the whole destination makes replay unavailable and retained identities cannot be reused", async () => {
    const scenario = await createScenario({ sourceFromCurrentUser: true })
    const context = testUtils.functionContext({ userId: scenario.currentUser.id })
    const input = request(scenario, 261n)
    await forwardMessages(input, context)
    await deleteChat({ peer: scenario.toPeerId }, context)
    await expect(forwardMessages(input, context)).rejects.toBeDefined()
    expect(await db.select().from(messageSubmissions)).toHaveLength(1)
    await expect(forwardMessages({ ...input, toPeerId: scenario.fromPeerId }, context))
      .rejects.toMatchObject({ code: RealtimeRpcError.Code.BAD_REQUEST })
    expect(await db.select().from(messages).where(eq(messages.chatId, scenario.sourceChatId))).toHaveLength(1)
  })

  test("a selected opener carries visible content and an ordinary child link without transferring structure or ACL", async () => {
    const scenario = await createScenario({ sourceFromCurrentUser: true })
    const [source] = await db.select().from(messages).where(and(eq(messages.chatId, scenario.sourceChatId), eq(messages.messageId, 1)))
    if (!source) throw new Error("missing source")
    const [child] = await db.insert(chats).values({
      type: "thread", title: "Existing private child", createdBy: scenario.currentUser.id,
      publicThread: false, parentChatId: scenario.sourceChatId,
    }).returning()
    if (!child) throw new Error("missing child")
    await db.insert(subthreadParentMessages).values({ childChatId: child.id, parentMessageGlobalId: source.globalId })
    const context = testUtils.functionContext({ userId: scenario.currentUser.id })
    const result = await forwardMessages(request(scenario), context)
    const forwarded = await MessageModel.getMessage(Number(result.receipts[0]!.messageId), scenario.destinationThreadId)
    expect(forwarded.text).toBe(`forward me\n\nExisting private child\n\ninline://chat/${child.id}\n\nSource: inline://chat/${scenario.sourceChatId}?message_id=1`)
    expect(forwarded.entities?.entities.find((entity) => entity.type === MessageEntity_Type.THREAD)?.entity)
      .toEqual({ oneofKind: "thread", thread: { chatId: BigInt(child.id) } })
    expect(await db.select().from(subthreadParentMessages)).toHaveLength(1)
    const participants = await db.select().from(chatParticipants)
      .where(eq(chatParticipants.chatId, scenario.destinationThreadId))
    const recipient = participants.find((participant) => participant.userId !== scenario.currentUser.id)
    if (!recipient) throw new Error("missing destination participant")
    await expect(AccessGuards.ensureChatAccess(child, recipient.userId)).rejects.toBeDefined()
    const [sourceChat] = await db.select().from(chats).where(eq(chats.id, scenario.sourceChatId))
    if (!sourceChat) throw new Error("missing source chat")
    await expect(AccessGuards.ensureChatAccess(sourceChat, recipient.userId)).rejects.toBeDefined()
    const history = await getChatHistory({ peerId: scenario.toPeerId }, context)
    expect(history.messages[0]?.subthread).toBeUndefined()
    expect(history.messages[0]?.isForwarded).toBe(true)
  })
})
