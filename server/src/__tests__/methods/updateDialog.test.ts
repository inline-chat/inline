import { describe, test, expect } from "bun:test"
import { setupTestLifecycle, testUtils } from "../setup"
import { handler } from "../../methods/updateDialog"
import type { HandlerContext } from "../../controllers/helpers"
import { UpdateBucket } from "@in/server/db/schema/updates"
import { UpdatesModel } from "@in/server/db/models/updates"
import { db } from "../../db"
import type { ServerUpdate } from "@in/protocol/server"

describe("updateDialog", () => {
  setupTestLifecycle()

  const makeContext = (userId: number): HandlerContext => ({
    currentUserId: userId,
    currentSessionId: 0,
    ip: "127.0.0.1",
  })

  test("archives and unarchives dialogs while enqueuing user updates", async () => {
    type UserDialogArchivedUpdate = Extract<ServerUpdate["update"], { oneofKind: "userDialogArchived" }>
    type DecryptedUserDialogArchivedUpdate = UpdatesModel.DecryptedUpdate & {
      payload: ServerUpdate & { update: UserDialogArchivedUpdate }
    }

    const isUserDialogArchivedUpdate = (
      update: UpdatesModel.DecryptedUpdate,
    ): update is DecryptedUserDialogArchivedUpdate => update.payload.update.oneofKind === "userDialogArchived"

    const userA = await testUtils.createUser("archive-owner@example.com")
    const userB = await testUtils.createUser("archive-peer@example.com")
    if (!userA || !userB) throw new Error("Failed to create users")

    await testUtils.createPrivateChatWithOptionalDialog({
      userA,
      userB,
      createDialogForUserA: true,
      createDialogForUserB: true,
    })

    await handler({ peerUserId: String(userB.id), archived: true }, makeContext(userA.id))
    await handler({ peerUserId: String(userB.id), archived: false }, makeContext(userA.id))

    const userUpdates = await db.query.updates.findMany({
      where: {
        bucket: UpdateBucket.User,
        entityId: userA.id,
      },
    })

    const archivedUpdates = userUpdates
      .map((update) => UpdatesModel.decrypt(update))
      .filter(isUserDialogArchivedUpdate)
      .sort((a, b) => a.seq - b.seq)

    expect(archivedUpdates).toHaveLength(2)
    expect(archivedUpdates[0]?.payload.update.oneofKind).toBe("userDialogArchived")
    expect(archivedUpdates[0]?.payload.update.userDialogArchived.archived).toBe(true)
    expect(archivedUpdates[0]?.payload.update.userDialogArchived.peerId?.type.oneofKind).toBe("user")
    expect(archivedUpdates[0]?.payload.update.userDialogArchived.peerId?.type.user.userId).toBe(BigInt(userB.id))
    expect(archivedUpdates[1]?.payload.update.oneofKind).toBe("userDialogArchived")
    expect(archivedUpdates[1]?.payload.update.userDialogArchived.archived).toBe(false)
  })
})
