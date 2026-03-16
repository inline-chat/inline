import { describe, expect, test } from "bun:test"
import { and, eq } from "drizzle-orm"
import { db } from "@in/server/db"
import { UpdatesModel } from "@in/server/db/models/updates"
import * as schema from "@in/server/db/schema"
import { UpdateBucket } from "@in/server/db/schema/updates"
import { showChatInSidebar } from "@in/server/functions/messages.showChatInSidebar"
import { setupTestLifecycle, testUtils } from "../setup"

describe("messages.showChatInSidebar", () => {
  setupTestLifecycle()

  test("promotes a hidden linked reply-thread dialog and enqueues chatOpen", async () => {
    const owner = await testUtils.createUser("show-sidebar-owner@example.com")
    const viewer = await testUtils.createUser("show-sidebar-viewer@example.com")

    const parentChat = await testUtils.createChat(null, "Parent Thread", "thread", false, owner.id)
    if (!parentChat) {
      throw new Error("Parent chat not created")
    }

    await testUtils.addParticipant(parentChat.id, owner.id)
    await testUtils.addParticipant(parentChat.id, viewer.id)

    await db.insert(schema.messages).values({
      chatId: parentChat.id,
      messageId: 1,
      fromId: owner.id,
      text: "anchor",
    })

    const [childChat] = await db
      .insert(schema.chats)
      .values({
        type: "thread",
        title: "Re: anchor",
        publicThread: false,
        createdBy: owner.id,
        parentChatId: parentChat.id,
        parentMessageId: 1,
      })
      .returning()

    if (!childChat) {
      throw new Error("Child chat not created")
    }

    await db.insert(schema.dialogs).values({
      chatId: childChat.id,
      userId: viewer.id,
      spaceId: childChat.spaceId,
      sidebarVisible: false,
    })

    const result = await showChatInSidebar(
      {
        peerId: {
          type: {
            oneofKind: "chat",
            chat: { chatId: BigInt(childChat.id) },
          },
        },
      },
      testUtils.functionContext({ userId: viewer.id }),
    )

    expect(result.chat.id).toBe(BigInt(childChat.id))
    expect(result.dialog.chatId).toBe(BigInt(childChat.id))
    expect(result.dialog.sidebarVisible).toBe(true)

    const [updatedDialog] = await db
      .select()
      .from(schema.dialogs)
      .where(and(eq(schema.dialogs.chatId, childChat.id), eq(schema.dialogs.userId, viewer.id)))
      .limit(1)

    expect(updatedDialog?.sidebarVisible).toBe(true)

    const userUpdates = await db.query.updates.findMany({
      where: {
        bucket: UpdateBucket.User,
        entityId: viewer.id,
      },
    })

    const hasChatOpen = userUpdates
      .map((update) => UpdatesModel.decrypt(update))
      .some((update) => update.payload.update.oneofKind === "userChatOpen")

    expect(hasChatOpen).toBe(true)
  })
})
