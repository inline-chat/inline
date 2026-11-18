import { chatId, messageId, userId } from "@inline/ids"
import { describe, expect, it } from "vitest"
import { Db } from "../index"
import {
  DbObjectKind,
  MessageSendingStatus,
  messageKey,
  type Message,
} from "../models"
import { createGatedStore } from "./gated-store"

const chat = chatId(10)

const message = (
  id: number,
  text: string,
  status?: MessageSendingStatus,
): Message => ({
  kind: DbObjectKind.Message,
  id: messageKey(chat, messageId(id)),
  messageId: messageId(id),
  chatId: chat,
  fromId: userId(7),
  message: text,
  date: 1_000 + id,
  ...(status ? { status } : {}),
})

/** Yield to the event loop until a held read has run against SQLite. */
const untilHeld = async (
  gated: ReturnType<typeof createGatedStore>,
  count: number,
) => {
  for (let turn = 0; turn < 200; turn += 1) {
    if (gated.heldReads >= count) return
    await new Promise<void>((resolve) => setImmediate(resolve))
  }
  throw new Error(`read never reached the gate (${gated.heldReads})`)
}

const setup = async () => {
  const gated = createGatedStore()
  const db = new Db({ autoHydrate: false, persistenceStore: gated.store })
  await db.openPersistence()
  await db.commit(() => {
    db.insert({ kind: DbObjectKind.Chat, id: chat, lastMsgId: messageId(1) })
    db.insert(message(1, "first"))
  })
  return { gated, db }
}

describe("invariant 13: a disk read never overwrites a write accepted after it began", () => {
  it("invariant 13: an acknowledged send does not come back as a duplicate Sending row", async () => {
    const { gated, db } = await setup()
    const temporary = message(5_000, "hello", MessageSendingStatus.Sending)
    await db.commit(() => db.insert(temporary))
    db.releaseResidentMessageWindow(chat)
    db.activateResidentMessageWindow(chat)

    // The window read starts and sees the temporary row on disk.
    gated.holdReads()
    const read = db.hydrateMessageWindow(chat, { limit: 50 })
    await untilHeld(gated, 1)

    // The acknowledgement replaces the temporary row with the server's.
    const acknowledged = {
      ...message(2, "hello", MessageSendingStatus.Sent),
    }
    await db.commit(() => {
      db.delete(db.ref(DbObjectKind.Message, temporary.id))
      db.insert(acknowledged)
    })
    db.migrateResidentMessageWindowKey(chat, temporary.id, acknowledged.id)

    gated.releaseReads()
    await read

    expect(db.get(db.ref(DbObjectKind.Message, temporary.id))).toBeUndefined()
    expect(db.get(db.ref(DbObjectKind.Message, acknowledged.id))).toMatchObject({
      status: MessageSendingStatus.Sent,
    })
    const window = db.fullChatWindows.keys(chat)
    expect(window).not.toContain(temporary.id)
    expect(window).toContain(acknowledged.id)
  })

  it("invariant 13: an edit made while an around read is in flight is not reverted", async () => {
    const { gated, db } = await setup()
    await db.commit(() => {
      db.insert(message(2, "second"))
      db.insert(message(3, "third"))
    })

    gated.holdReads()
    const read = db.loadLocalWindowAroundMessage(chat, {
      messageId: messageId(2),
      beforeLimit: 5,
      afterLimit: 5,
    })
    await untilHeld(gated, 1)

    await db.commit(() => {
      db.update({ ...message(2, "second (edited)"), editDate: 2_000 })
    })

    gated.releaseReads()
    await read

    expect(
      db.get(db.ref(DbObjectKind.Message, messageKey(chat, messageId(2))))
        ?.message,
    ).toBe("second (edited)")
  })

  it("invariant 13: an edit to an evicted message is not reverted by an earlier read", async () => {
    const { gated, db } = await setup()
    const key = messageKey(chat, messageId(1))
    db.activateResidentMessageWindow(chat)
    db.releaseResidentMessageWindow(chat)
    await db.commit(() => {
      db.update({ kind: DbObjectKind.Chat, id: chat, lastMsgId: messageId(9) })
    })
    db.releaseResidentMessageWindow(chat)
    expect(db.get(db.ref(DbObjectKind.Message, key))).toBeUndefined()

    gated.holdReads()
    const read = db.hydrateObjects(DbObjectKind.Message, [key])
    await untilHeld(gated, 1)

    // The edit arrives while the row is not resident.
    db.storeNonResidentObject({ ...message(1, "first (edited)"), editDate: 2_000 })
    await db.flushPersistence()

    gated.releaseReads()
    await read

    expect(db.get(db.ref(DbObjectKind.Message, key))?.message).toBe(
      "first (edited)",
    )
  })

  it("invariant 13: a deletion during full-kind hydration is not resurrected", async () => {
    const { gated, db } = await setup()
    const fresh = new Db({ autoHydrate: false, persistenceStore: gated.store })

    gated.holdReads()
    const read = fresh.hydrateKinds([DbObjectKind.Chat])
    await untilHeld(gated, 1)
    await fresh.commit(() => {
      fresh.delete(fresh.ref(DbObjectKind.Chat, chat))
    })
    gated.releaseReads()
    await read

    expect(fresh.get(fresh.ref(DbObjectKind.Chat, chat))).toBeUndefined()
    expect(db.get(db.ref(DbObjectKind.Chat, chat))).toBeDefined()
  })

  it("invariant 13: a read never admits a row over an accepted write that has not committed", async () => {
    const { gated, db } = await setup()
    const key = messageKey(chat, messageId(1))
    db.activateResidentMessageWindow(chat)
    db.releaseResidentMessageWindow(chat)
    db.update({ kind: DbObjectKind.Chat, id: chat, lastMsgId: messageId(9) })
    await db.flushPersistence()
    db.releaseResidentMessageWindow(chat)

    // A delete is accepted but its transaction has not run yet.
    gated.holdWrites()
    db.storeNonResidentObject({ ...message(1, "first (edited)") })
    db.delete(db.ref(DbObjectKind.Message, key))

    // The read starts now and sees the old row on disk.
    await db.hydrateObjects(DbObjectKind.Message, [key])
    expect(db.get(db.ref(DbObjectKind.Message, key))).toBeUndefined()

    gated.releaseWrites()
    await db.flushPersistence()
    expect(db.get(db.ref(DbObjectKind.Message, key))).toBeUndefined()
  })
})
