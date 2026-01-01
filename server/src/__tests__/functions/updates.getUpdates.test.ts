import { describe, test, expect } from "bun:test"
import { getUpdates } from "@in/server/functions/updates.getUpdates"
import { testUtils, setupTestLifecycle } from "../setup"
import { db } from "../../db"
import { updates, UpdateBucket } from "../../db/schema/updates"
import { GetUpdatesResult_ResultType, InputPeer } from "@in/protocol/core"
import type { ServerUpdate } from "@in/protocol/server"
import { encodeDateStrict } from "@in/server/realtime/encoders/helpers"
import { UpdatesModel } from "@in/server/db/models/updates"

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

describe("getUpdates", () => {
  setupTestLifecycle()

  test("returns TOO_LONG with correct seq when gap is too large", async () => {
    // 1. Setup User and Chat
    const { users, space } = await testUtils.createSpaceWithMembers("Test Space", ["user@example.com"])
    const user = users[0]
    const chat = await testUtils.createChat(space.id, "Test Chat", "thread")
    if (!chat) throw new Error("Chat creation failed")

    // 2. Insert updates (seq 1 to 10)
    // We just need dummy payload
    const dummyPayload = Buffer.from([1, 2, 3])
    
    for (let i = 1; i <= 10; i++) {
      await db.insert(updates).values({
        bucket: UpdateBucket.Chat,
        entityId: chat.id,
        seq: i,
        payload: dummyPayload,
      })
    }

    // 3. Call getUpdates with fast-forward parameters
    // startSeq=0, totalLimit=1
    const inputPeer: InputPeer = {
      type: {
        oneofKind: "chat",
        chat: { chatId: BigInt(chat.id) }
      }
    }
    
    const result = await getUpdates({
      bucket: {
        type: {
          oneofKind: "chat",
          chat: { peerId: inputPeer }
        }
      },
      startSeq: 0n,
      totalLimit: 1
    }, { currentUserId: user.id } as any)

    // 4. Verify result
    expect(result.resultType).toBe(GetUpdatesResult_ResultType.TOO_LONG)
    expect(Number(result.seq)).toBe(10) 
  })

  test("respects seqEnd for sliced getUpdates", async () => {
    const { users } = await testUtils.createSpaceWithMembers("SeqEnd Slice", ["seqend@example.com"])
    const user = users[0]
    if (!user) throw new Error("User creation failed")

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

    const result = await getUpdates({
      bucket: { type: { oneofKind: "user", user: {} } },
      startSeq: 0n,
      seqEnd: 3n,
      totalLimit: 1000
    }, { currentUserId: user.id } as any)

    expect(Number(result.seq)).toBe(3)
    expect(result.final).toBe(true)
    expect(result.resultType).toBe(GetUpdatesResult_ResultType.SLICE)
    expect(result.updates.length).toBe(3)
  })

  test("caps totalLimit to MAX_TOTAL_LIMIT", async () => {
    const { users } = await testUtils.createSpaceWithMembers("TotalLimit Cap", ["cap@example.com"])
    const user = users[0]
    if (!user) throw new Error("User creation failed")

    const dummyPayload = Buffer.from([1, 2, 3])
    await db.insert(updates).values({
      bucket: UpdateBucket.User,
      entityId: user.id,
      seq: 1501,
      payload: dummyPayload,
    })

    const result = await getUpdates({
      bucket: { type: { oneofKind: "user", user: {} } },
      startSeq: 0n,
      totalLimit: 5000
    }, { currentUserId: user.id } as any)

    expect(result.resultType).toBe(GetUpdatesResult_ResultType.TOO_LONG)
  })
})
