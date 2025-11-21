import { describe, test, expect } from "bun:test"
import { getUpdates } from "@in/server/functions/updates.getUpdates"
import { testUtils, setupTestLifecycle } from "../setup"
import { db } from "../../db"
import { updates, UpdateBucket } from "../../db/schema/updates"
import { GetUpdatesResult_ResultType, InputPeer } from "@in/protocol/core"

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
    const dummyPayload = new Uint8Array([1, 2, 3])
    
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
})
