import { beforeAll, describe, expect, test } from "bun:test"
import { InputPeer, Message, MessageEntity_Type, type EditMessageResult } from "@inline-chat/protocol/core"
import { setupTestDatabase, testUtils } from "../setup"
import { sendMessage } from "@in/server/functions/messages.sendMessage"
import { editMessage } from "@in/server/functions/messages.editMessage"
import type { DbChat, DbUser } from "@in/server/db/schema"
import type { FunctionContext } from "@in/server/functions/_types"
import { db } from "@in/server/db"
import { users } from "@in/server/db/schema"
import { eq } from "drizzle-orm"

let currentUser: DbUser
let privateChat: DbChat
let privateChatPeerId: InputPeer
let context: FunctionContext
let userIndex = 0

const runId = Date.now()
const nextEmail = (label: string) => `${label}-${runId}-${userIndex++}@example.com`

function extractEditedMessage(result: EditMessageResult): Message | null {
  const update = result.updates[0]
  if (update?.update.oneofKind !== "editMessage") {
    return null
  }
  return update.update.editMessage?.message ?? null
}

describe("editMessage function", () => {
  beforeAll(async () => {
    await setupTestDatabase()
    currentUser = (await testUtils.createUser(nextEmail("edit-user")))!
    privateChat = (await testUtils.createPrivateChat(currentUser, currentUser))!
    privateChatPeerId = {
      type: { oneofKind: "chat" as const, chat: { chatId: BigInt(privateChat.id) } },
    }
    context = testUtils.functionContext({ userId: currentUser.id, sessionId: 1 })
  })

  test("parses markdown when parseMarkdown is enabled", async () => {
    const sent = await sendMessage(
      {
        peerId: privateChatPeerId,
        message: "initial",
      },
      context,
    )
    const messageId = sent.updates[0]?.update.oneofKind === "updateMessageId"
      ? sent.updates[0].update.updateMessageId?.messageId
      : undefined
    expect(messageId).toBeTruthy()

    const result = await editMessage(
      {
        messageId: messageId!,
        peer: privateChatPeerId,
        text: "hello **world** and `code`",
        parseMarkdown: true,
      },
      context,
    )

    const message = extractEditedMessage(result)
    expect(message).toBeTruthy()
    expect(message?.message).toBe("hello world and code")
    expect(message?.entities?.entities).toHaveLength(2)
    expect(message?.entities?.entities[0]?.type).toBe(MessageEntity_Type.BOLD)
    expect(message?.entities?.entities[0]?.offset).toBe(6n)
    expect(message?.entities?.entities[0]?.length).toBe(5n)
    expect(message?.entities?.entities[1]?.type).toBe(MessageEntity_Type.CODE)
    expect(message?.entities?.entities[1]?.offset).toBe(16n)
    expect(message?.entities?.entities[1]?.length).toBe(4n)
  })

  test("resolves @username mentions while parsing markdown edits", async () => {
    const mentionedUser = await testUtils.createUser(nextEmail("edit-mentioned"))
    await db.update(users).set({ username: "editmentioned" }).where(eq(users.id, mentionedUser!.id)).execute()

    const sent = await sendMessage(
      {
        peerId: privateChatPeerId,
        message: "initial mention",
      },
      context,
    )
    const messageId = sent.updates[0]?.update.oneofKind === "updateMessageId"
      ? sent.updates[0].update.updateMessageId?.messageId
      : undefined
    expect(messageId).toBeTruthy()

    const result = await editMessage(
      {
        messageId: messageId!,
        peer: privateChatPeerId,
        text: "check **@editmentioned**",
        parseMarkdown: true,
      },
      context,
    )

    const message = extractEditedMessage(result)
    const sendReference = await sendMessage(
      {
        peerId: privateChatPeerId,
        message: "check **@editmentioned**",
        parseMarkdown: true,
      },
      context,
    )
    const sentMessage =
      sendReference.updates[1]?.update.oneofKind === "newMessage"
        ? sendReference.updates[1].update.newMessage?.message
        : null

    expect(message).toBeTruthy()
    expect(sentMessage).toBeTruthy()
    expect(message?.message).toBe("check @editmentioned")
    expect(message?.entities).toEqual(sentMessage?.entities)
    expect(message?.entities?.entities[0]?.type).toBe(MessageEntity_Type.BOLD)
  })
})
