import { describe, expect, test } from "bun:test"
import { handler as getDialogsHandler } from "../../methods/getDialogs"
import { testUtils, defaultTestContext, setupTestLifecycle } from "../setup"
import { db } from "../../db"
import * as schema from "../../db/schema"
import { eq, and, or } from "drizzle-orm"
import { getChats } from "@in/server/functions/messages.getChats"

// Helper to create a HandlerContext
const makeHandlerContext = (userId: number): any => ({
  currentUserId: userId,
  currentSessionId: defaultTestContext.sessionId,
  ip: "127.0.0.1",
})

describe("getChats", () => {
  setupTestLifecycle()

  test("returns empty arrays when user has no dialogs", async () => {
    const { space, users } = await testUtils.createSpaceWithMembers("DM Space", ["empty@example.com"])
    const [chat] = await db
      .insert(schema.chats)
      .values({
        spaceId: space.id,
        type: "thread",
        publicThread: true,
        title: "Orphan Thread",
      })
      .returning()

    // create dialog for the user
    // await db.insert(schema.dialogs).values({
    //   chatId: chat!.id,
    //   userId: users[0].id,
    // })

    const [chat2] = await db
      .insert(schema.chats)
      .values({
        spaceId: space.id,
        type: "thread",
        publicThread: false,
        title: "Private Thread",
      })
      .returning()
    const _ = await db.insert(schema.chatParticipants).values({
      chatId: chat2!.id,
      userId: users[0].id,
    })

    const result = await getChats({}, makeHandlerContext(users[0].id))
    console.log(result)
  })
})
