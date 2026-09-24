import { afterEach, describe, expect, mock, spyOn, test } from "bun:test"
import { and, eq, inArray } from "drizzle-orm"
import { setupTestLifecycle, testUtils } from "../setup"
import { db } from "@in/server/db"
import { UpdatesModel } from "@in/server/db/models/updates"
import { UpdateBucket, updates, users } from "@in/server/db/schema"
import { UserBucketUpdates } from "@in/server/modules/updates/userBucketUpdates"
import type { ServerUpdate } from "@in/server/protocol/server"
import { encodeDateStrict } from "@in/server/realtime/encoders/helpers"
import { waitForPostCommitHooks } from "@in/server/db/commitHooks"
import * as durable from "@in/server/modules/internalMessaging/durable"

const archivedUpdate = (chatId: bigint = 123n): ServerUpdate["update"] => ({
  oneofKind: "userDialogArchived",
  userDialogArchived: {
    peerId: { type: { oneofKind: "chat", chat: { chatId } } },
    archived: true,
  },
})

describe("UserBucketUpdates", () => {
  setupTestLifecycle()
  afterEach(async () => {
    await waitForPostCommitHooks()
    mock.restore()
  })

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

  test("a user-row waiter cannot receive a later seq with an earlier date", async () => {
    const user = await testUtils.createUser("user-bucket-date-order@example.com")
    if (!user) throw new Error("Failed to create user")

    let waitingEnqueue: Promise<{ seq: number; date: Date }> | undefined
    const first = await db.transaction(async (tx) => {
      await tx.select({ id: users.id }).from(users).where(eq(users.id, user.id)).for("update").limit(1)

      // This enqueue samples its timestamp before waiting on our user lock in
      // the regressed implementation. Keeping it queued while the lock owner
      // writes seq 1 deterministically reproduces the timestamp inversion.
      waitingEnqueue = UserBucketUpdates.enqueue({
        userId: user.id,
        update: {
          oneofKind: "userDialogArchived",
          userDialogArchived: {
            peerId: { type: { oneofKind: "chat", chat: { chatId: 123n } } },
            archived: false,
          },
        },
      })

      await Bun.sleep(25)
      return await UserBucketUpdates.enqueue(
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
    })

    if (!waitingEnqueue) throw new Error("Failed to start waiting enqueue")
    const second = await waitingEnqueue

    expect(first.seq).toBe(1)
    expect(second.seq).toBe(2)
    expect(second.date.getTime()).toBeGreaterThanOrEqual(first.date.getTime())

    const stored = await db
      .select({ seq: updates.seq, date: updates.date })
      .from(updates)
      .where(and(eq(updates.bucket, UpdateBucket.User), eq(updates.entityId, user.id)))
      .orderBy(updates.seq)
    expect(stored.map((row) => row.seq)).toEqual([1, 2])
    expect(stored[1]!.date.getTime()).toBeGreaterThanOrEqual(stored[0]!.date.getTime())
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

  test("publishes a provided-transaction frontier only after the outer commit", async () => {
    const user = await testUtils.createUser("user-bucket-commit-hook@example.com")
    const published: Parameters<typeof durable.publishDurableReference>[0][] = []
    spyOn(durable, "publishDurableReference").mockImplementation((input) => {
      published.push(input)
    })

    const result = await db.transaction(async (tx) => {
      const update = await UserBucketUpdates.enqueue(
        { userId: user.id, update: archivedUpdate() },
        { tx, senderUserId: user.id, excludeSessionId: 42 },
      )
      expect(published).toEqual([])
      return update
    })

    await waitForPostCommitHooks()
    expect(published).toEqual([{
      bucket: { kind: "user", userId: user.id },
      frontier: result.seq,
      senderUserId: user.id,
      excludeSessionId: 42,
    }])
    const committed = await db
      .select({ seq: updates.seq })
      .from(updates)
      .where(and(eq(updates.bucket, UpdateBucket.User), eq(updates.entityId, user.id)))
    expect(committed.map((row) => row.seq)).toEqual([result.seq])
  })

  test("drops a provided-transaction frontier when its outer transaction rolls back", async () => {
    const user = await testUtils.createUser("user-bucket-outer-rollback@example.com")
    const publish = spyOn(durable, "publishDurableReference").mockImplementation(() => {})

    await expect(db.transaction(async (tx) => {
      await UserBucketUpdates.enqueue({ userId: user.id, update: archivedUpdate() }, { tx })
      throw new Error("intentional outer rollback")
    })).rejects.toThrow("intentional outer rollback")

    await waitForPostCommitHooks()
    expect(publish).not.toHaveBeenCalled()
    const committed = await db
      .select({ id: updates.id })
      .from(updates)
      .where(and(eq(updates.bucket, UpdateBucket.User), eq(updates.entityId, user.id)))
    expect(committed).toEqual([])
  })

  test("discards savepoint hooks when a nested transaction rolls back", async () => {
    const outerUser = await testUtils.createUser("user-bucket-savepoint-outer@example.com")
    const rolledBackUser = await testUtils.createUser("user-bucket-savepoint-inner@example.com")
    const published: Parameters<typeof durable.publishDurableReference>[0][] = []
    spyOn(durable, "publishDurableReference").mockImplementation((input) => {
      published.push(input)
    })

    await db.transaction(async (tx) => {
      await UserBucketUpdates.enqueue({ userId: outerUser.id, update: archivedUpdate() }, { tx })
      await expect(tx.transaction(async (nestedTx) => {
        await UserBucketUpdates.enqueue({ userId: rolledBackUser.id, update: archivedUpdate() }, { tx: nestedTx })
        throw new Error("intentional savepoint rollback")
      })).rejects.toThrow("intentional savepoint rollback")
    })

    await waitForPostCommitHooks()
    expect(published).toEqual([{ bucket: { kind: "user", userId: outerUser.id }, frontier: 1 }])
  })

  test("drops a successful savepoint frontier when its outer transaction rolls back", async () => {
    const user = await testUtils.createUser("user-bucket-savepoint-outer-rollback@example.com")
    const publish = spyOn(durable, "publishDurableReference").mockImplementation(() => {})

    await expect(db.transaction(async (tx) => {
      await tx.transaction(async (nestedTx) => {
        await UserBucketUpdates.enqueue({ userId: user.id, update: archivedUpdate() }, { tx: nestedTx })
      })
      throw new Error("intentional outer rollback after savepoint release")
    })).rejects.toThrow("intentional outer rollback after savepoint release")

    await waitForPostCommitHooks()
    expect(publish).not.toHaveBeenCalled()
  })

  test("coalesces nested user frontiers to the committed maximum sequence", async () => {
    const user = await testUtils.createUser("user-bucket-coalesced-frontier@example.com")
    const published: Parameters<typeof durable.publishDurableReference>[0][] = []
    spyOn(durable, "publishDurableReference").mockImplementation((input) => {
      published.push(input)
    })

    const result = await db.transaction(async (tx) => {
      await UserBucketUpdates.enqueue({ userId: user.id, update: archivedUpdate(1n) }, { tx })
      await tx.transaction(async (nestedTx) => {
        await UserBucketUpdates.enqueue({ userId: user.id, update: archivedUpdate(2n) }, { tx: nestedTx })
      })
      return await UserBucketUpdates.enqueue({ userId: user.id, update: archivedUpdate(3n) }, { tx })
    })

    await waitForPostCommitHooks()
    expect(published).toEqual([{ bucket: { kind: "user", userId: user.id }, frontier: result.seq }])
    expect(result.seq).toBe(3)
  })

  test("does not exclude a session when a coalesced frontier spans sessions", async () => {
    const user = await testUtils.createUser("user-bucket-mixed-session-frontier@example.com")
    const published: Parameters<typeof durable.publishDurableReference>[0][] = []
    spyOn(durable, "publishDurableReference").mockImplementation((input) => {
      published.push(input)
    })

    const latest = await db.transaction(async (tx) => {
      await UserBucketUpdates.enqueue(
        { userId: user.id, update: archivedUpdate(1n) },
        { tx, senderUserId: user.id, excludeSessionId: 10 },
      )
      return await UserBucketUpdates.enqueue(
        { userId: user.id, update: archivedUpdate(2n) },
        { tx, senderUserId: user.id, excludeSessionId: 20 },
      )
    })

    await waitForPostCommitHooks()
    expect(published).toEqual([{ bucket: { kind: "user", userId: user.id }, frontier: latest.seq }])
  })

  test("keeps a committed update successful when its post-commit publication fails", async () => {
    const user = await testUtils.createUser("user-bucket-publication-failure@example.com")
    const publish = spyOn(durable, "publishDurableReference").mockImplementation(() => {
      throw new Error("intentional broker failure")
    })

    const result = await db.transaction(async (tx) => {
      return await UserBucketUpdates.enqueue({ userId: user.id, update: archivedUpdate() }, { tx })
    })

    await waitForPostCommitHooks()
    expect(publish).toHaveBeenCalledTimes(1)
    const committed = await db
      .select({ seq: updates.seq })
      .from(updates)
      .where(and(eq(updates.bucket, UpdateBucket.User), eq(updates.entityId, user.id)))
    expect(committed.map((row) => row.seq)).toEqual([result.seq])
  })
})
