import { describe, expect, test } from "bun:test"
import { setupTestLifecycle, testUtils } from "@in/server/__tests__/setup"
import type { HandlerContext } from "@in/server/realtime/types"
import { SessionsModel } from "@in/server/db/models/sessions"
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

    const joined = await createSpaceV3({ name: "Disposable" }, context(member.id, memberSession.session.id))
    if (!joined.space) throw new Error("missing joined space")
    await leaveSpaceV3({ spaceId: joined.space.id }, context(member.id, memberSession.session.id))
    await deleteSpaceV3({ spaceId: owned.space.id }, context(owner.id, ownerSession.session.id))
  })

  test("updates only the current session metadata", async () => {
    const user = await testUtils.createUser("v3-session-update@example.com")
    const account = await testUtils.createSessionForUser(user.id, { clientType: "macos" })
    const result = await updateSessionV3({ timeZone: "Asia/Tehran", deviceName: "Inline Dev" }, context(
      user.id,
      account.session.id,
    ))
    expect(result.session?.timezone).toBe("Asia/Tehran")
    expect(result.session?.deviceName).toBe("Inline Dev")
    expect((await SessionsModel.getById(account.session.id)).personalData.timezone).toBe("Asia/Tehran")
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
