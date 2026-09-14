import { describe, it, expect, beforeEach, vi } from "vitest"
import { chatId, messageId, userId } from "@inline/ids"
import { Db } from "./index"
import { DbObjectKind, messageKey, type User, type Message } from "./models"
import { DbQueryPlanType } from "./types"

const message = (
  rawMessageId: number,
  rawChatId: number,
  rawFromId: number,
  text: string,
): Message => ({
  kind: DbObjectKind.Message,
  id: messageKey(chatId(rawChatId), messageId(rawMessageId)),
  messageId: messageId(rawMessageId),
  fromId: userId(rawFromId),
  chatId: chatId(rawChatId),
  message: text,
})

const aliceId = userId(1)

describe("Database", () => {
  let db: Db

  beforeEach(() => {
    db = new Db()
  })

  // 1. Insert and get
  it("should insert and retrieve an object", () => {
    const user: User = { kind: DbObjectKind.User, id: aliceId, firstName: "Alice" }
    db.insert(user)

    const ref = db.ref(DbObjectKind.User, aliceId)
    const retrieved = db.get(ref)

    expect(retrieved).toEqual(user)
  })

  // 2. Update
  it("should update an existing object", () => {
    const user: User = { kind: DbObjectKind.User, id: aliceId, firstName: "Alice" }
    db.insert(user)

    const updated: User = { kind: DbObjectKind.User, id: aliceId, firstName: "Bob" }
    db.update(updated)

    const ref = db.ref(DbObjectKind.User, aliceId)
    const retrieved = db.get(ref)

    expect(retrieved?.firstName).toBe("Bob")
  })

  it("should merge updates without clearing existing fields", () => {
    const user: User = { kind: DbObjectKind.User, id: aliceId, firstName: "Alice", lastName: "Smith" }
    db.insert(user)

    const updated: User = { kind: DbObjectKind.User, id: aliceId, firstName: "Bob" }
    db.update(updated)

    const ref = db.ref(DbObjectKind.User, aliceId)
    const retrieved = db.get(ref)

    expect(retrieved?.firstName).toBe("Bob")
    expect(retrieved?.lastName).toBe("Smith")
  })

  it("should replace on insert when object already exists", () => {
    const user: User = { kind: DbObjectKind.User, id: aliceId, firstName: "Alice", lastName: "Smith" }
    db.insert(user)

    const replacement: User = { kind: DbObjectKind.User, id: aliceId, lastName: "Jones" }
    db.insert(replacement)

    const ref = db.ref(DbObjectKind.User, aliceId)
    const retrieved = db.get(ref)

    expect(retrieved?.firstName).toBeUndefined()
    expect(retrieved?.lastName).toBe("Jones")
  })

  it("should replace a complete object and clear optional fields", () => {
    const user: User = {
      kind: DbObjectKind.User,
      id: aliceId,
      firstName: "Alice",
      lastName: "Smith",
    }
    db.insert(user)

    db.replace({
      kind: DbObjectKind.User,
      id: aliceId,
      lastName: "Jones",
    })

    expect(db.get(db.ref(DbObjectKind.User, aliceId))).toEqual({
      kind: DbObjectKind.User,
      id: aliceId,
      lastName: "Jones",
    })
  })

  // 3. Delete
  it("should delete an object", () => {
    const user: User = { kind: DbObjectKind.User, id: aliceId, firstName: "Alice" }
    db.insert(user)

    const ref = db.ref(DbObjectKind.User, aliceId)
    db.delete(ref)

    const retrieved = db.get(ref)
    expect(retrieved).toBeUndefined()
  })

  // 4. Ref stability
  it("should return stable refs for the same id", () => {
    const user: User = { kind: DbObjectKind.User, id: aliceId, firstName: "Alice" }
    db.insert(user)

    const ref1 = db.ref(DbObjectKind.User, aliceId)
    const ref2 = db.ref(DbObjectKind.User, aliceId)

    expect(ref1).toBe(ref2) // Same object reference
  })

  // 5. Object subscription
  it("should notify object subscribers on update", () => {
    const user: User = { kind: DbObjectKind.User, id: aliceId, firstName: "Alice" }
    db.insert(user)

    const ref = db.ref(DbObjectKind.User, aliceId)
    const callback = vi.fn()

    db.subscribeToObject(ref, callback)

    const updated: User = { kind: DbObjectKind.User, id: aliceId, firstName: "Bob" }
    db.update(updated)

    expect(callback).toHaveBeenCalledTimes(1)
  })

  // 6. Object subscription unsubscribe
  it("should stop notifying after unsubscribe", () => {
    const user: User = { kind: DbObjectKind.User, id: aliceId, firstName: "Alice" }
    db.insert(user)

    const ref = db.ref(DbObjectKind.User, aliceId)
    const callback = vi.fn()

    const { unsubscribe } = db.subscribeToObject(ref, callback)
    unsubscribe()

    const updated: User = { kind: DbObjectKind.User, id: aliceId, firstName: "Bob" }
    db.update(updated)

    expect(callback).not.toHaveBeenCalled()
  })

  // 7. Query collection
  it("should query objects with predicate", () => {
    const msg1 = message(1, 100, 1, "Hello")
    const msg2 = message(2, 200, 1, "World")
    const msg3 = message(3, 100, 2, "Hi")

    db.insert(msg1)
    db.insert(msg2)
    db.insert(msg3)

    const chat100Messages = db.queryCollection(
      DbQueryPlanType.Objects,
      DbObjectKind.Message,
      (m: Message) => m.chatId === chatId(100),
    )

    expect(chat100Messages).toHaveLength(2)
    expect(chat100Messages.map((m: Message) => m.messageId).sort()).toEqual([
      messageId(1),
      messageId(3),
    ])
  })

  it("keeps identical protocol message IDs isolated by chat", () => {
    const first = message(7, 100, 1, "First chat")
    const second = message(7, 200, 2, "Second chat")

    db.insert(first)
    db.insert(second)

    expect(
      db.get(
        db.ref(
          DbObjectKind.Message,
          messageKey(chatId(100), messageId(7)),
        ),
      )?.message,
    ).toBe("First chat")
    expect(
      db.get(
        db.ref(
          DbObjectKind.Message,
          messageKey(chatId(200), messageId(7)),
        ),
      )?.message,
    ).toBe("Second chat")
    expect(
      db.queryCollection(DbQueryPlanType.Objects, DbObjectKind.Message, () => true),
    ).toHaveLength(2)
  })

  // 8. Query caching
  it("should cache query results", () => {
    const msg = message(1, 100, 1, "Hello")
    db.insert(msg)

    const predicate = (m: Message) => m.chatId === chatId(100)
    const key = "test-query"

    // Subscribe to register the query
    db.subscribeToQuery(key, DbQueryPlanType.Objects, DbObjectKind.Message, predicate, () => {})

    // First call computes
    const result1 = db.queryCached(key, DbQueryPlanType.Objects, DbObjectKind.Message, predicate)
    // Second call should return cached
    const result2 = db.queryCached(key, DbQueryPlanType.Objects, DbObjectKind.Message, predicate)

    expect(result1).toBe(result2) // Same array reference
  })

  // 9. Batch operations
  it("should batch notifications", () => {
    const callback = vi.fn()
    const predicate = () => true
    const key = "batch-test"

    db.subscribeToQuery(key, DbQueryPlanType.Objects, DbObjectKind.Message, predicate, callback)
    // Clear the initial dirty state
    db.queryCached(key, DbQueryPlanType.Objects, DbObjectKind.Message, predicate)
    callback.mockClear()

    db.batch(() => {
      for (let i = 0; i < 10; i++) {
        const msg = message(i, 100, 1, `Msg ${i}`)
        db.insert(msg)
      }
    })

    // Should only notify once, not 10 times
    expect(callback).toHaveBeenCalledTimes(1)
  })

  // 10. Nested batch operations
  it("should handle nested batches correctly", () => {
    const callback = vi.fn()
    const predicate = () => true
    const key = "nested-batch-test"

    db.subscribeToQuery(key, DbQueryPlanType.Objects, DbObjectKind.Message, predicate, callback)
    db.queryCached(key, DbQueryPlanType.Objects, DbObjectKind.Message, predicate)
    callback.mockClear()

    db.batch(() => {
      const msg1 = message(1, 100, 1, "Outer 1")
      db.insert(msg1)

      db.batch(() => {
        const msg2 = message(2, 100, 1, "Inner")
        db.insert(msg2)
      })

      // Inner batch should not trigger yet
      expect(callback).not.toHaveBeenCalled()

      const msg3 = message(3, 100, 1, "Outer 2")
      db.insert(msg3)
    })

    // All notifications should fire once at the end
    expect(callback).toHaveBeenCalledTimes(1)

    // All messages should be inserted
    const messages = db.queryCollection(DbQueryPlanType.Objects, DbObjectKind.Message, () => true)
    expect(messages).toHaveLength(3)
  })
})
