import { beforeEach, describe, expect, test } from "bun:test"
import { InputPeer } from "@inline-chat/protocol/core"
import { db } from "@in/server/db"
import { chatParticipants, chats, members, messages } from "@in/server/db/schema"
import type { DbUser } from "@in/server/db/schema"
import { MessageModel } from "@in/server/db/models/messages"
import { forwardMessages } from "@in/server/functions/messages.forwardMessages"
import { eq } from "drizzle-orm"
import { setupTestLifecycle, testUtils } from "../setup"

const runId = Date.now()
let userIndex = 0
const nextEmail = (label: string) => `${label}-${runId}-${userIndex++}@example.com`

setupTestLifecycle()

type Scenario = {
  currentUser: DbUser
  dmPeerUser: DbUser
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
})
