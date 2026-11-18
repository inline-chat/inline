import { afterAll, beforeAll, describe, expect, test } from "bun:test"
import { eq } from "drizzle-orm"
import { db } from "@in/server/db"
import { dialogs, users } from "@in/server/db/schema"
import { UserSettingsModel } from "@in/server/db/models/userSettings/userSettings"
import { getChat } from "@in/server/functions/messages.getChat"
import { getChats } from "@in/server/functions/messages.getChats"
import { defaultTestContext, setupTestLifecycle, testUtils } from "../setup"

describe("DM privacy in a single-connection snapshot", () => {
  const previous = process.env["INLINE_DATABASE_QUERY_POOL_MAX"]
  beforeAll(() => { process.env["INLINE_DATABASE_QUERY_POOL_MAX"] = "1" })
  setupTestLifecycle()
  afterAll(() => {
    if (previous === undefined) delete process.env["INLINE_DATABASE_QUERY_POOL_MAX"]
    else process.env["INLINE_DATABASE_QUERY_POOL_MAX"] = previous
  })

  test("the list, page and single chat can encode restricted peers while holding their read transaction", async () => {
    const viewer = await testUtils.createUser("pool-viewer@example.test")
    const owner = await testUtils.createUser("pool-owner@example.test")
    const dm = await testUtils.createPrivateChat(viewer, owner)
    if (!dm) throw new Error("Missing DM fixture")
    await db.insert(dialogs).values({ userId: viewer.id, chatId: dm.id, peerUserId: owner.id })
    const rule = { audience: "nobody" as const, alwaysShare: [viewer.id] }
    await UserSettingsModel.updateGeneralWithPatch(owner.id, { privacy: { timeZone: rule, focusStatus: rule } })
    await db.update(users).set({ timeZone: "UTC", focused: true, focusUpdatedAt: new Date() }).where(eq(users.id, owner.id))
    const context = { currentUserId: viewer.id, currentSessionId: defaultTestContext.sessionId }
    for (const input of [{}, { limit: 10 }]) {
      const list = await getChats(input, context)
      expect(list.users.find(user => user.id === BigInt(owner.id))).toMatchObject({ timeZone: "UTC", status: { focus: { focused: true } } })
    }
    const chat = await getChat({ peerId: { type: { oneofKind: "user", user: { userId: BigInt(owner.id) } } } }, context)
    expect(chat.user).toMatchObject({ timeZone: "UTC", status: { focus: { focused: true } } })
  })
})
