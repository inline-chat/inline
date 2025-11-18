import { describe, it, expect } from "bun:test"
import { Sync } from "@in/server/modules/updates/sync"
import { UpdateBucket, updates } from "@in/server/db/schema/updates"
import { setupTestLifecycle, testUtils } from "../setup"
import { db } from "@in/server/db"
import type { ServerUpdate } from "@in/protocol/server"
import { encodeDateStrict } from "@in/server/realtime/encoders/helpers"
import { UpdatesModel } from "@in/server/db/models/updates"
import type { Peer } from "@in/protocol/core"
import { Functions } from "@in/server/functions"
import { GetUpdatesResult_ResultType } from "@in/protocol/core"

const insertServerUpdate = async (params: {
  bucket: UpdateBucket
  entityId: number
  seq: number
  payload: ServerUpdate["update"]
}) => {
  const now = new Date()
  const serverUpdate: ServerUpdate = {
    seq: params.seq,
    date: encodeDateStrict(now),
    update: params.payload,
  }
  const record = UpdatesModel.build(serverUpdate)
  await db.insert(updates).values({
    bucket: params.bucket,
    entityId: params.entityId,
    seq: params.seq,
    payload: record.encrypted,
    date: now,
  })
}

describe("Sync core flow", () => {
  setupTestLifecycle()

  it("processes chat participant deletions end-to-end", async () => {
    const { space, users } = await testUtils.createSpaceWithMembers("Sync Chat", ["a@sync.com", "b@sync.com"])
    const userA = users[0]
    const userB = users[1]
    if (!space || !userA || !userB) {
      throw new Error("Failed to set up private thread test")
    }
    const chat = await testUtils.createChat(space.id, "Private Thread", "thread", false)
    if (!chat) {
      throw new Error("Failed to create private thread")
    }
    await testUtils.addParticipant(chat.id, userA.id)
    await testUtils.addParticipant(chat.id, userB.id)

    await insertServerUpdate({
      bucket: UpdateBucket.Chat,
      entityId: chat.id,
      seq: 1,
      payload: {
        oneofKind: "participantDelete",
        participantDelete: {
          chatId: BigInt(chat.id),
          userId: BigInt(userB.id),
        },
      },
    })

    const { updates: dbUpdates } = await Sync.getUpdates({
      bucket: { type: UpdateBucket.Chat, chatId: chat.id },
      seqStart: 0,
      limit: 10,
    })

    const peer: Peer = { type: { oneofKind: "chat", chat: { chatId: BigInt(chat.id) } } }
    const { updates: inflated } = await Sync.processChatUpdates({
      chatId: chat.id,
      peerId: peer,
      updates: dbUpdates,
      userId: userA.id,
    })

    expect(inflated).toHaveLength(1)
    const [firstUpdate] = inflated
    expect(firstUpdate?.seq).toBe(1)
    if (!firstUpdate || firstUpdate.update.oneofKind !== "participantDelete") {
      throw new Error("Expected participantDelete update")
    }
    expect(firstUpdate.update.participantDelete.userId).toBe(BigInt(userB.id))
  })

  it("inflates user bucket updates for chat participant removal", async () => {
    const { users } = await testUtils.createSpaceWithMembers("User Sync", ["user@sync.com"])
    const user = users[0]
    if (!user) {
      throw new Error("Failed to create user")
    }
    await insertServerUpdate({
      bucket: UpdateBucket.User,
      entityId: user.id,
      seq: 1,
      payload: {
        oneofKind: "userChatParticipantDelete",
        userChatParticipantDelete: {
          chatId: 42n,
          userId: BigInt(user.id),
        },
      },
    })

    const { updates: dbUpdates } = await Sync.getUpdates({
      bucket: { type: UpdateBucket.User, userId: user.id },
      seqStart: 0,
      limit: 10,
    })

    const updates = Sync.inflateUserUpdates(dbUpdates)
    expect(updates).toHaveLength(1)
    const [userUpdate] = updates
    if (!userUpdate || userUpdate.update.oneofKind !== "participantDelete") {
      throw new Error("Expected participantDelete from user bucket")
    }
    expect(userUpdate.update.participantDelete.chatId).toBe(42n)
  })

  it("inflates space bucket updates for member removal", async () => {
    const { space, users } = await testUtils.createSpaceWithMembers("Space Sync", ["space@sync.com"])
    const user = users[0]
    if (!space || !user) {
      throw new Error("Failed to create space sync fixtures")
    }

    await insertServerUpdate({
      bucket: UpdateBucket.Space,
      entityId: space.id,
      seq: 1,
      payload: {
        oneofKind: "spaceRemoveMember",
        spaceRemoveMember: {
          spaceId: BigInt(space.id),
          userId: BigInt(user.id),
        },
      },
    })

    const { updates: dbUpdates } = await Sync.getUpdates({
      bucket: { type: UpdateBucket.Space, spaceId: space.id },
      seqStart: 0,
      limit: 10,
    })

    const updates = Sync.inflateSpaceUpdates(dbUpdates)
    expect(updates).toHaveLength(1)
    const [spaceUpdate] = updates
    if (!spaceUpdate || spaceUpdate.update.oneofKind !== "spaceMemberDelete") {
      throw new Error("Expected spaceMemberDelete update")
    }
    expect(spaceUpdate.update.spaceMemberDelete.userId).toBe(BigInt(user.id))
  })

  it("respects sequence offsets when fetching updates", async () => {
    const { users } = await testUtils.createSpaceWithMembers("Seq Sync", ["seq@sync.com"])
    const user = users[0]
    if (!user) {
      throw new Error("Failed to create seq user")
    }

    await insertServerUpdate({
      bucket: UpdateBucket.User,
      entityId: user.id,
      seq: 1,
      payload: {
        oneofKind: "userChatParticipantDelete",
        userChatParticipantDelete: {
          chatId: 1n,
          userId: BigInt(user.id),
        },
      },
    })
    await insertServerUpdate({
      bucket: UpdateBucket.User,
      entityId: user.id,
      seq: 2,
      payload: {
        oneofKind: "userChatParticipantDelete",
        userChatParticipantDelete: {
          chatId: 2n,
          userId: BigInt(user.id),
        },
      },
    })

    const { updates: dbUpdates } = await Sync.getUpdates({
      bucket: { type: UpdateBucket.User, userId: user.id },
      seqStart: 1,
      limit: 10,
    })

    expect(dbUpdates).toHaveLength(1)
    const [secondUpdate] = dbUpdates
    expect(secondUpdate?.seq).toBe(2)
  })

  it("returns metadata when fetching updates via Functions", async () => {
    const { users } = await testUtils.createSpaceWithMembers("Metadata Sync", ["meta@sync.com"])
    const user = users[0]
    if (!user) {
      throw new Error("Failed to create metadata user")
    }

    await insertServerUpdate({
      bucket: UpdateBucket.User,
      entityId: user.id,
      seq: 1,
      payload: {
        oneofKind: "userChatParticipantDelete",
        userChatParticipantDelete: {
          chatId: 99n,
          userId: BigInt(user.id),
        },
      },
    })

    const result = await Functions.updates.getUpdates(
      {
        bucket: { type: { oneofKind: "user", user: {} } },
        startSeq: 0n,
        totalLimit: 10,
      },
      testUtils.functionContext({ userId: user.id }),
    )

    expect(result.seq).toBe(1n)
    expect(result.final).toBe(true)
    expect(result.resultType).toBe(GetUpdatesResult_ResultType.SLICE)
    expect(result.updates).toHaveLength(1)
  })

  it("returns TOO_LONG when total limit is exceeded", async () => {
    const { users } = await testUtils.createSpaceWithMembers("Too Long Sync", ["toolong@sync.com"])
    const user = users[0]
    if (!user) {
      throw new Error("Failed to create too-long user")
    }

    await insertServerUpdate({
      bucket: UpdateBucket.User,
      entityId: user.id,
      seq: 5,
      payload: {
        oneofKind: "userChatParticipantDelete",
        userChatParticipantDelete: {
          chatId: 100n,
          userId: BigInt(user.id),
        },
      },
    })

    const result = await Functions.updates.getUpdates(
      {
        bucket: { type: { oneofKind: "user", user: {} } },
        startSeq: 0n,
        totalLimit: 2,
      },
      testUtils.functionContext({ userId: user.id }),
    )

    expect(result.resultType).toBe(GetUpdatesResult_ResultType.TOO_LONG)
    expect(result.updates).toHaveLength(0)
    expect(result.final).toBe(false)
  })
})
