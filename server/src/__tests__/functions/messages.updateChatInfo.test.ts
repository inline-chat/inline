import { describe, expect, test } from "bun:test"
import { eq } from "drizzle-orm"
import { db } from "@in/server/db"
import * as schema from "@in/server/db/schema"
import { updateChatInfo } from "@in/server/functions/messages.updateChatInfo"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { setupTestLifecycle, testUtils } from "../setup"

async function createPrivateSpaceReplyThread(label: string, actorRole: "admin" | "member") {
  const owner = await testUtils.createUser(`rename-reply-${label}-owner@example.com`)
  const actor = await testUtils.createUser(`rename-reply-${label}-${actorRole}@example.com`)
  const space = await testUtils.createSpace(`Rename Reply ${label} Space`)
  if (!owner || !actor || !space) {
    throw new Error("Reply thread permission fixture not created")
  }

  await db.insert(schema.members).values([
    { spaceId: space.id, userId: owner.id, role: "owner" },
    { spaceId: space.id, userId: actor.id, role: actorRole },
  ])

  const parentChat = await testUtils.createChat(space.id, "Private Parent", "thread", false, owner.id)
  if (!parentChat) {
    throw new Error("Parent chat not created")
  }
  await testUtils.addParticipant(parentChat.id, owner.id)
  await db.insert(schema.messages).values({
    chatId: parentChat.id,
    messageId: 1,
    fromId: owner.id,
    text: "anchor",
  })

  const [replyThread] = await db
    .insert(schema.chats)
    .values({
      type: "thread",
      spaceId: space.id,
      title: "Re: anchor",
      isUntitled: true,
      publicThread: false,
      createdBy: owner.id,
      parentChatId: parentChat.id,
      parentMessageId: 1,
    })
    .returning()

  if (!replyThread) {
    throw new Error("Reply thread not created")
  }

  return { actor, replyThread }
}

describe("messages.updateChatInfo", () => {
  setupTestLifecycle()

  test("renames linked reply threads through inherited parent access", async () => {
    const owner = await testUtils.createUser("rename-reply-owner@example.com")
    const participant = await testUtils.createUser("rename-reply-participant@example.com")

    const parentChat = await testUtils.createChat(null, "Parent Thread", "thread", false, owner.id)
    if (!parentChat) {
      throw new Error("Parent chat not created")
    }

    await testUtils.addParticipant(parentChat.id, owner.id)
    await testUtils.addParticipant(parentChat.id, participant.id)

    await db.insert(schema.messages).values({
      chatId: parentChat.id,
      messageId: 1,
      fromId: owner.id,
      text: "anchor",
    })

    const [replyThread] = await db
      .insert(schema.chats)
      .values({
        type: "thread",
        title: "Re: anchor",
        isUntitled: true,
        publicThread: false,
        createdBy: owner.id,
        parentChatId: parentChat.id,
        parentMessageId: 1,
      })
      .returning()

    if (!replyThread) {
      throw new Error("Reply thread not created")
    }

    const result = await updateChatInfo(
      {
        chatId: replyThread.id,
        title: "Renamed reply",
      },
      testUtils.functionContext({ userId: participant.id }),
    )

    expect(result.chat.title).toBe("Renamed reply")

    const [saved] = await db
      .select({ title: schema.chats.title, isUntitled: schema.chats.isUntitled })
      .from(schema.chats)
      .where(eq(schema.chats.id, replyThread.id))
      .limit(1)

    expect(saved?.title).toBe("Renamed reply")
    expect(saved?.isUntitled).toBeNull()
  })

  test("allows space admins to rename private reply threads", async () => {
    const { actor: admin, replyThread } = await createPrivateSpaceReplyThread("admin", "admin")

    const result = await updateChatInfo(
      {
        chatId: replyThread.id,
        title: "Admin renamed reply",
      },
      testUtils.functionContext({ userId: admin.id }),
    )

    expect(result.chat.title).toBe("Admin renamed reply")
  })

  test("rejects non-participant space members for private reply threads", async () => {
    const { actor: member, replyThread } = await createPrivateSpaceReplyThread("deny", "member")

    await expect(
      updateChatInfo(
        {
          chatId: replyThread.id,
          title: "Unauthorized rename",
        },
        testUtils.functionContext({ userId: member.id }),
      ),
    ).rejects.toMatchObject({ code: RealtimeRpcError.Code.PEER_ID_INVALID })
  })
})
