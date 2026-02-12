import { describe, expect, test } from "bun:test"
import { and, eq, inArray } from "drizzle-orm"
import { setupTestLifecycle, testUtils } from "../setup"
import { db } from "@in/server/db"
import { UpdatesModel } from "@in/server/db/models/updates"
import { UpdateBucket, updates, users } from "@in/server/db/schema"
import { UserBucketUpdates } from "@in/server/modules/updates/userBucketUpdates"
import type { ServerUpdate } from "@inline-chat/protocol/server"
import { encodeDateStrict } from "@in/server/realtime/encoders/helpers"

describe("UserBucketUpdates", () => {
  setupTestLifecycle()

  test("lazy-inits users.updateSeq from existing updates and continues monotonically", async () => {
    const user = await testUtils.createUser("user-bucket-seq@example.com")
    if (!user) throw new Error("Failed to create user")

    const seed = async (seq: number) => {
      const now = new Date()
      const serverUpdate: ServerUpdate = {
        seq,
        date: encodeDateStrict(now),
        update: {
          oneofKind: "userMarkAsUnread",
          userMarkAsUnread: {
            peerId: { type: { oneofKind: "chat", chat: { chatId: 123n } } },
            unreadMark: false,
          },
        },
      }
      const record = UpdatesModel.build(serverUpdate)
      await db.insert(updates).values({
        bucket: UpdateBucket.User,
        entityId: user.id,
        seq,
        payload: record.encrypted,
        date: now,
      })
    }

    await seed(5)
    await seed(9)

    // Simulate pre-migration users that have existing updates but no persisted counter.
    await db.update(users).set({ updateSeq: null }).where(eq(users.id, user.id))
    const [before] = await db.select({ updateSeq: users.updateSeq }).from(users).where(eq(users.id, user.id)).limit(1)
    expect(before?.updateSeq ?? null).toBe(null)

    const r1 = await UserBucketUpdates.enqueue({
      userId: user.id,
      update: {
        oneofKind: "userReadMaxId",
        userReadMaxId: {
          peerId: { type: { oneofKind: "chat", chat: { chatId: 123n } } },
          readMaxId: 1n,
          unreadCount: 0,
        },
      },
    })
    expect(r1.seq).toBe(10)

    const r2 = await UserBucketUpdates.enqueue({
      userId: user.id,
      update: {
        oneofKind: "userReadMaxId",
        userReadMaxId: {
          peerId: { type: { oneofKind: "chat", chat: { chatId: 123n } } },
          readMaxId: 2n,
          unreadCount: 0,
        },
      },
    })
    expect(r2.seq).toBe(11)

    const [after] = await db.select({ updateSeq: users.updateSeq }).from(users).where(eq(users.id, user.id)).limit(1)
    expect(after?.updateSeq).toBe(11)

    const rows = await db
      .select({ seq: updates.seq })
      .from(updates)
      .where(and(eq(updates.bucket, UpdateBucket.User), eq(updates.entityId, user.id), inArray(updates.seq, [10, 11])))
    expect(rows.map((r) => r.seq).sort((a, b) => a - b)).toEqual([10, 11])
  })

  test("recovers when users.updateSeq is non-null but stale behind persisted updates", async () => {
    const user = await testUtils.createUser("user-bucket-stale-counter@example.com")
    if (!user) throw new Error("Failed to create user")

    const seed = async (seq: number) => {
      const now = new Date()
      const serverUpdate: ServerUpdate = {
        seq,
        date: encodeDateStrict(now),
        update: {
          oneofKind: "userMarkAsUnread",
          userMarkAsUnread: {
            peerId: { type: { oneofKind: "chat", chat: { chatId: 321n } } },
            unreadMark: false,
          },
        },
      }
      const record = UpdatesModel.build(serverUpdate)
      await db.insert(updates).values({
        bucket: UpdateBucket.User,
        entityId: user.id,
        seq,
        payload: record.encrypted,
        date: now,
      })
    }

    await seed(1)
    await seed(7)
    await db.update(users).set({ updateSeq: 2 }).where(eq(users.id, user.id))

    const result = await UserBucketUpdates.enqueue({
      userId: user.id,
      update: {
        oneofKind: "userReadMaxId",
        userReadMaxId: {
          peerId: { type: { oneofKind: "chat", chat: { chatId: 321n } } },
          readMaxId: 8n,
          unreadCount: 0,
        },
      },
    })

    expect(result.seq).toBe(8)

    const [after] = await db.select({ updateSeq: users.updateSeq }).from(users).where(eq(users.id, user.id)).limit(1)
    expect(after?.updateSeq).toBe(8)
  })

  test("concurrent enqueues don't create duplicate seq", async () => {
    const user = await testUtils.createUser("user-bucket-concurrency@example.com")
    if (!user) throw new Error("Failed to create user")

    const [a, b] = await Promise.all([
      UserBucketUpdates.enqueue({
        userId: user.id,
        update: {
          oneofKind: "userDialogArchived",
          userDialogArchived: {
            peerId: { type: { oneofKind: "chat", chat: { chatId: 123n } } },
            archived: true,
          },
        },
      }),
      UserBucketUpdates.enqueue({
        userId: user.id,
        update: {
          oneofKind: "userDialogArchived",
          userDialogArchived: {
            peerId: { type: { oneofKind: "chat", chat: { chatId: 123n } } },
            archived: false,
          },
        },
      }),
    ])

    const seqs = [a.seq, b.seq].sort((x, y) => x - y)
    expect(seqs).toEqual([1, 2])
  })

  test("enqueueMany preserves input order and same-user ordering", async () => {
    const userA = await testUtils.createUser("user-bucket-many-a@example.com")
    const userB = await testUtils.createUser("user-bucket-many-b@example.com")
    if (!userA || !userB) throw new Error("Failed to create users")

    const results = await UserBucketUpdates.enqueueMany([
      {
        userId: userB.id,
        update: {
          oneofKind: "userDialogArchived",
          userDialogArchived: {
            peerId: { type: { oneofKind: "chat", chat: { chatId: 123n } } },
            archived: true,
          },
        },
      },
      {
        userId: userA.id,
        update: {
          oneofKind: "userDialogArchived",
          userDialogArchived: {
            peerId: { type: { oneofKind: "chat", chat: { chatId: 123n } } },
            archived: true,
          },
        },
      },
      {
        // Same user as first entry; must keep semantic order even though we sort by userId internally.
        userId: userB.id,
        update: {
          oneofKind: "userDialogArchived",
          userDialogArchived: {
            peerId: { type: { oneofKind: "chat", chat: { chatId: 123n } } },
            archived: false,
          },
        },
      },
    ])

    // Returned array must match input order.
    expect(results).toHaveLength(3)
    expect(results[0]?.seq).toBe(1)
    expect(results[1]?.seq).toBe(1)
    expect(results[2]?.seq).toBe(2)
  })

  test("enqueueMany returns empty array for empty input", async () => {
    const results = await UserBucketUpdates.enqueueMany([])
    expect(results).toEqual([])
  })

  test("enqueue throws when user does not exist and does not insert an update row", async () => {
    const missingUserId = 999999999

    await expect(
      UserBucketUpdates.enqueue({
        userId: missingUserId,
        update: {
          oneofKind: "userDialogArchived",
          userDialogArchived: {
            peerId: { type: { oneofKind: "chat", chat: { chatId: 123n } } },
            archived: true,
          },
        },
      }),
    ).rejects.toThrow()

    const rows = await db
      .select({ id: updates.id })
      .from(updates)
      .where(and(eq(updates.bucket, UpdateBucket.User), eq(updates.entityId, missingUserId)))

    expect(rows).toHaveLength(0)
  })

  test("enqueue/enqueueMany respect provided transaction", async () => {
    const user = await testUtils.createUser("user-bucket-tx@example.com")
    if (!user) throw new Error("Failed to create user")

    await db.transaction(async (tx) => {
      const r1 = await UserBucketUpdates.enqueue(
        {
          userId: user.id,
          update: {
            oneofKind: "userDialogArchived",
            userDialogArchived: {
              peerId: { type: { oneofKind: "chat", chat: { chatId: 123n } } },
              archived: true,
            },
          },
        },
        { tx },
      )
      expect(r1.seq).toBe(1)

      const [r2] = await UserBucketUpdates.enqueueMany(
        [
          {
            userId: user.id,
            update: {
              oneofKind: "userDialogArchived",
              userDialogArchived: {
                peerId: { type: { oneofKind: "chat", chat: { chatId: 123n } } },
                archived: false,
              },
            },
          },
        ],
        { tx },
      )

      expect(r2?.seq).toBe(2)
    })
  })
})
