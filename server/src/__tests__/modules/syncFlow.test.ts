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
import { Encoders } from "@in/server/realtime/encoders/encoders"
import { MembersModel } from "@in/server/db/models/members"

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

  it("inflates new chat updates from chat bucket", async () => {
    const { space, users } = await testUtils.createSpaceWithMembers("New Chat Sync", ["newchat@sync.com"])
    const user = users[0]
    if (!space || !user) {
      throw new Error("Failed to create new chat fixtures")
    }

    const chat = await testUtils.createChat(space.id, "New Chat", "thread", true)
    if (!chat) {
      throw new Error("Failed to create chat")
    }

    await insertServerUpdate({
      bucket: UpdateBucket.Chat,
      entityId: chat.id,
      seq: 1,
      payload: {
        oneofKind: "newChat",
        newChat: {
          chatId: BigInt(chat.id),
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
      userId: user.id,
    })

    expect(inflated).toHaveLength(1)
    const [firstUpdate] = inflated
    if (!firstUpdate || firstUpdate.update.oneofKind !== "newChat") {
      throw new Error("Expected newChat update")
    }
    const newChat = firstUpdate.update.newChat.chat
    if (!newChat) {
      throw new Error("Expected chat payload in newChat update")
    }
    expect(newChat.id).toBe(BigInt(chat.id))
  })

  it("inflates delete chat updates from chat bucket", async () => {
    const { space, users } = await testUtils.createSpaceWithMembers("Delete Chat Sync", ["delete@sync.com"])
    const user = users[0]
    if (!space || !user) {
      throw new Error("Failed to create delete chat fixtures")
    }

    const chat = await testUtils.createChat(space.id, "Delete Chat", "thread", true)
    if (!chat) {
      throw new Error("Failed to create chat")
    }

    await insertServerUpdate({
      bucket: UpdateBucket.Chat,
      entityId: chat.id,
      seq: 1,
      payload: {
        oneofKind: "deleteChat",
        deleteChat: {
          chatId: BigInt(chat.id),
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
      userId: user.id,
    })

    expect(inflated).toHaveLength(1)
    const [firstUpdate] = inflated
    if (!firstUpdate || firstUpdate.update.oneofKind !== "deleteChat") {
      throw new Error("Expected deleteChat update")
    }
    const peerType = firstUpdate.update.deleteChat.peerId?.type
    if (!peerType || peerType.oneofKind !== "chat") {
      throw new Error("Expected chat peer in deleteChat update")
    }
    expect(peerType.chat.chatId).toBe(BigInt(chat.id))
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

  it("inflates space bucket updates for member addition", async () => {
    const { space, users } = await testUtils.createSpaceWithMembers("Space Member Add Sync", ["add@sync.com"])
    const user = users[0]
    if (!space || !user) {
      throw new Error("Failed to create member add fixtures")
    }

    const member = await MembersModel.getMemberByUserId(space.id, user.id)
    if (!member) {
      throw new Error("Failed to load member")
    }

    await insertServerUpdate({
      bucket: UpdateBucket.Space,
      entityId: space.id,
      seq: 1,
      payload: {
        oneofKind: "spaceMemberAdd",
        spaceMemberAdd: {
          member: Encoders.member(member),
          user: Encoders.user({ user, min: false }),
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
    if (!spaceUpdate || spaceUpdate.update.oneofKind !== "spaceMemberAdd") {
      throw new Error("Expected spaceMemberAdd update")
    }
    const memberPayload = spaceUpdate.update.spaceMemberAdd.member
    if (!memberPayload) {
      throw new Error("Expected member payload in spaceMemberAdd update")
    }
    expect(memberPayload.userId).toBe(BigInt(user.id))
  })

  it("inflates user bucket updates for join space", async () => {
    const { space, users } = await testUtils.createSpaceWithMembers("Join Space Sync", ["join@sync.com"])
    const user = users[0]
    if (!space || !user) {
      throw new Error("Failed to create join space fixtures")
    }

    const member = await MembersModel.getMemberByUserId(space.id, user.id)
    if (!member) {
      throw new Error("Failed to load member")
    }

    await insertServerUpdate({
      bucket: UpdateBucket.User,
      entityId: user.id,
      seq: 1,
      payload: {
        oneofKind: "userJoinSpace",
        userJoinSpace: {
          space: Encoders.space(space, { encodingForUserId: user.id }),
          member: Encoders.member(member),
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
    if (!userUpdate || userUpdate.update.oneofKind !== "joinSpace") {
      throw new Error("Expected joinSpace update")
    }
    const spacePayload = userUpdate.update.joinSpace.space
    if (!spacePayload) {
      throw new Error("Expected space payload in joinSpace update")
    }
    expect(spacePayload.id).toBe(BigInt(space.id))
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

  it("respects seqEnd when fetching updates", async () => {
    const { users } = await testUtils.createSpaceWithMembers("Seq End Sync", ["seqend@sync.com"])
    const user = users[0]
    if (!user) {
      throw new Error("Failed to create seqEnd user")
    }

    for (let seq = 1; seq <= 5; seq += 1) {
      await insertServerUpdate({
        bucket: UpdateBucket.User,
        entityId: user.id,
        seq,
        payload: {
          oneofKind: "userChatParticipantDelete",
          userChatParticipantDelete: {
            chatId: BigInt(seq),
          },
        },
      })
    }

    const { updates: dbUpdates, latestSeq } = await Sync.getUpdates({
      bucket: { type: UpdateBucket.User, userId: user.id },
      seqStart: 0,
      seqEnd: 3,
      limit: 10,
    })

    expect(dbUpdates).toHaveLength(3)
    expect(dbUpdates[2]?.seq).toBe(3)
    expect(latestSeq).toBe(3)
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
        },
      },
    })

    const result = await Functions.updates.getUpdates(
      {
        bucket: { type: { oneofKind: "user", user: {} } },
        startSeq: 0n,
        seqEnd: 0n,
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
        },
      },
    })

    const result = await Functions.updates.getUpdates(
      {
        bucket: { type: { oneofKind: "user", user: {} } },
        startSeq: 0n,
        seqEnd: 0n,
        totalLimit: 2,
      },
      testUtils.functionContext({ userId: user.id }),
    )

    expect(result.resultType).toBe(GetUpdatesResult_ResultType.TOO_LONG)
    expect(result.updates).toHaveLength(0)
    expect(result.final).toBe(false)
  })
})
