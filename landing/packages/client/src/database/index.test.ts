import { describe, it, expect, beforeEach, vi } from "vitest"
import { Db } from "./index"
import { DbObjectKind, type User, type Message } from "./models"
import { DbQueryPlanType } from "./types"

describe("Database", () => {
  let db: Db

  beforeEach(() => {
    db = new Db()
  })

  // 1. Insert and get
  it("should insert and retrieve an object", () => {
    const user: User = { kind: DbObjectKind.User, id: 1, firstName: "Alice" }
    db.insert(user)

    const ref = db.ref(DbObjectKind.User, 1)
    const retrieved = db.get(ref)

    expect(retrieved).toEqual(user)
  })

  // 2. Update
  it("should update an existing object", () => {
    const user: User = { kind: DbObjectKind.User, id: 1, firstName: "Alice" }
    db.insert(user)

    const updated: User = { kind: DbObjectKind.User, id: 1, firstName: "Bob" }
    db.update(updated)

    const ref = db.ref(DbObjectKind.User, 1)
    const retrieved = db.get(ref)

    expect(retrieved?.firstName).toBe("Bob")
  })

  it("should merge updates without clearing existing fields", () => {
    const user: User = { kind: DbObjectKind.User, id: 1, firstName: "Alice", lastName: "Smith" }
    db.insert(user)

    const updated: User = { kind: DbObjectKind.User, id: 1, firstName: "Bob" }
    db.update(updated)

    const ref = db.ref(DbObjectKind.User, 1)
    const retrieved = db.get(ref)

    expect(retrieved?.firstName).toBe("Bob")
    expect(retrieved?.lastName).toBe("Smith")
  })

  it("should replace on insert when object already exists", () => {
    const user: User = { kind: DbObjectKind.User, id: 1, firstName: "Alice", lastName: "Smith" }
    db.insert(user)

    const replacement: User = { kind: DbObjectKind.User, id: 1, lastName: "Jones" }
    db.insert(replacement)

    const ref = db.ref(DbObjectKind.User, 1)
    const retrieved = db.get(ref)

    expect(retrieved?.firstName).toBeUndefined()
    expect(retrieved?.lastName).toBe("Jones")
  })

  // 3. Delete
  it("should delete an object", () => {
    const user: User = { kind: DbObjectKind.User, id: 1, firstName: "Alice" }
    db.insert(user)

    const ref = db.ref(DbObjectKind.User, 1)
    db.delete(ref)

    const retrieved = db.get(ref)
    expect(retrieved).toBeUndefined()
  })

  // 4. Ref stability
  it("should return stable refs for the same id", () => {
    const user: User = { kind: DbObjectKind.User, id: 1, firstName: "Alice" }
    db.insert(user)

    const ref1 = db.ref(DbObjectKind.User, 1)
    const ref2 = db.ref(DbObjectKind.User, 1)

    expect(ref1).toBe(ref2) // Same object reference
  })

  // 5. Object subscription
  it("should notify object subscribers on update", () => {
    const user: User = { kind: DbObjectKind.User, id: 1, firstName: "Alice" }
    db.insert(user)

    const ref = db.ref(DbObjectKind.User, 1)
    const callback = vi.fn()

    db.subscribeToObject(ref, callback)

    const updated: User = { kind: DbObjectKind.User, id: 1, firstName: "Bob" }
    db.update(updated)

    expect(callback).toHaveBeenCalledTimes(1)
  })

  // 6. Object subscription unsubscribe
  it("should stop notifying after unsubscribe", () => {
    const user: User = { kind: DbObjectKind.User, id: 1, firstName: "Alice" }
    db.insert(user)

    const ref = db.ref(DbObjectKind.User, 1)
    const callback = vi.fn()

    const { unsubscribe } = db.subscribeToObject(ref, callback)
    unsubscribe()

    const updated: User = { kind: DbObjectKind.User, id: 1, firstName: "Bob" }
    db.update(updated)

    expect(callback).not.toHaveBeenCalled()
  })

  // 7. Query collection
  it("should query objects with predicate", () => {
    const msg1: Message = { kind: DbObjectKind.Message, id: 1, fromId: 1, chatId: 100, message: "Hello" }
    const msg2: Message = { kind: DbObjectKind.Message, id: 2, fromId: 1, chatId: 200, message: "World" }
    const msg3: Message = { kind: DbObjectKind.Message, id: 3, fromId: 2, chatId: 100, message: "Hi" }

    db.insert(msg1)
    db.insert(msg2)
    db.insert(msg3)

    const chat100Messages = db.queryCollection(
      DbQueryPlanType.Objects,
      DbObjectKind.Message,
      (m: Message) => m.chatId === 100,
    )

    expect(chat100Messages).toHaveLength(2)
    expect(chat100Messages.map((m: Message) => m.id).sort()).toEqual([1, 3])
  })

  // 8. Query caching
  it("should cache query results", () => {
    const msg: Message = { kind: DbObjectKind.Message, id: 1, fromId: 1, chatId: 100, message: "Hello" }
    db.insert(msg)

    const predicate = (m: Message) => m.chatId === 100
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
        const msg: Message = { kind: DbObjectKind.Message, id: i, fromId: 1, chatId: 100, message: `Msg ${i}` }
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
      const msg1: Message = { kind: DbObjectKind.Message, id: 1, fromId: 1, chatId: 100, message: "Outer 1" }
      db.insert(msg1)

      db.batch(() => {
        const msg2: Message = { kind: DbObjectKind.Message, id: 2, fromId: 1, chatId: 100, message: "Inner" }
        db.insert(msg2)
      })

      // Inner batch should not trigger yet
      expect(callback).not.toHaveBeenCalled()

      const msg3: Message = { kind: DbObjectKind.Message, id: 3, fromId: 1, chatId: 100, message: "Outer 2" }
      db.insert(msg3)
    })

    // All notifications should fire once at the end
    expect(callback).toHaveBeenCalledTimes(1)

    // All messages should be inserted
    const messages = db.queryCollection(DbQueryPlanType.Objects, DbObjectKind.Message, () => true)
    expect(messages).toHaveLength(3)
  })
})
