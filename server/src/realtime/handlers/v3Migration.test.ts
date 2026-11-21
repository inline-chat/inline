import { describe, expect, test } from "bun:test"
import { setupTestLifecycle, testUtils } from "@in/server/__tests__/setup"
import type { HandlerContext } from "@in/server/realtime/types"
import { SessionsModel } from "@in/server/db/models/sessions"
import { db, schema } from "@in/server/db"
import {
  createSpaceV3,
  deleteSpaceV3,
  leaveSpaceV3,
  updateDialogArchivedV3,
  updateSessionV3,
} from "./v3Migration"

const context = (userId: number, sessionId: number): HandlerContext => ({
  userId,
  sessionId,
  connectionId: "v3-migration-test",
  sendRaw: () => {},
  sendRpcReply: () => {},
})

describe("V3 migration RPCs", () => {
  setupTestLifecycle()

  test("creates protocol-native space state and preserves delete/leave semantics", async () => {
    const owner = await testUtils.createUser("v3-space-owner@example.com")
    const ownerSession = await testUtils.createSessionForUser(owner.id)
    const member = await testUtils.createUser("v3-space-member@example.com")
    const memberSession = await testUtils.createSessionForUser(member.id)

    const owned = await createSpaceV3({ name: "Protocol Town" }, context(owner.id, ownerSession.session.id))
    if (!owned.space || !owned.member || !owned.chat || !owned.dialog) throw new Error("missing created space state")
    expect(owned.space.name).toBe("Protocol Town")
    expect(owned.member.spaceId).toBe(owned.space.id)
    expect(owned.chat.title).toBe("Protocol Town")
    expect(owned.dialog.open).toBe(true)

    const spaceId = owned.space.id
    await db.insert(schema.members).values({ spaceId: Number(spaceId), userId: member.id, role: "member" })
    await leaveSpaceV3({ spaceId }, context(member.id, memberSession.session.id))
    // The creator is the only owner, so they delete the Space instead of leaving it.
    await expect(leaveSpaceV3({ spaceId }, context(owner.id, ownerSession.session.id)))
      .rejects.toMatchObject({ type: "SPACE_LAST_OWNER" })
    await deleteSpaceV3({ spaceId }, context(owner.id, ownerSession.session.id))
  })

  test("updates only the current session metadata", async () => {
    const user = await testUtils.createUser("v3-session-update@example.com")
    const account = await testUtils.createSessionForUser(user.id, { clientType: "macos", clientVersion: "5843" })
    const other = await testUtils.createSessionForUser(user.id, { clientType: "macos", clientVersion: "5843" })
    const result = await updateSessionV3({
      timeZone: "Asia/Tehran", deviceName: "Inline Dev", clientVersion: "5999", osVersion: "27.0.1",
    }, context(
      user.id,
      account.session.id,
    ))
    expect(result.session?.timezone).toBe("Asia/Tehran")
    expect(result.session?.deviceName).toBe("Inline Dev")
    const updated = await SessionsModel.getById(account.session.id)
    expect(updated.personalData.timezone).toBe("Asia/Tehran")
    expect(updated.clientVersion).toBe("5999")
    expect(updated.osVersion).toBe("27.0.1")
    expect(result.session?.clientVersion).toBe("5999")
    expect((await SessionsModel.getById(other.session.id)).clientVersion).toBe("5843")
  })

  test("archives one dialog and returns the ordinary typed update", async () => {
    const user = await testUtils.createUser("v3-dialog-archive@example.com")
    const account = await testUtils.createSessionForUser(user.id)
    const created = await createSpaceV3({ name: "Archive Me" }, context(user.id, account.session.id))
    if (!created.chat) throw new Error("missing created chat")
    const peerId = { type: { oneofKind: "chat" as const, chat: { chatId: created.chat.id } } }

    const result = await updateDialogArchivedV3({ peerId, archived: true }, context(user.id, account.session.id))
    expect(result.updates).toEqual([{
      update: { oneofKind: "dialogArchived", dialogArchived: { peerId, archived: true } },
    }])
  })
})
