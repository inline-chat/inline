import { describe, expect, it } from "bun:test"
import { eq } from "drizzle-orm"
import { db } from "@in/server/db"
import { messages } from "@in/server/db/schema/messages"
import { decrypt, encrypt } from "@in/server/modules/encryption/encryption"
import { backfillMessageTextBatch } from "../../../scripts/helpers/backfill-message-text"
import { setupTestLifecycle, testUtils } from "../setup"

describe("legacy message text backfill", () => {
  setupTestLifecycle()
  const fixture = async () => {
    const user = await testUtils.createUser()
    const chat = await testUtils.createChat(null)
    return { fromId: user.id, chatId: chat!.id }
  }

  it("defaults to verification, then migrates bounded batches and can restart safely", async () => {
    const owner = await fixture()
    await db.insert(messages).values([1, 2, 3].map((messageId) => ({ ...owner, messageId, text: `synthetic ${messageId}` })))
    const dry = await backfillMessageTextBatch({ apply: false, batchSize: 2 })
    expect(dry).toMatchObject({ scanned: 2, verified: 2, migrated: 0, conflicts: 0, done: false })
    expect((await db.select().from(messages)).every((row) => row.text !== null)).toBe(true)
    const first = await backfillMessageTextBatch({ apply: true, batchSize: 2 })
    expect(first.migrated).toBe(2)
    const resumed = await backfillMessageTextBatch({ apply: true, afterId: BigInt(first.lastId), batchSize: 2 })
    expect(resumed).toMatchObject({ migrated: 1, done: true })
    expect((await backfillMessageTextBatch({ apply: true })).scanned).toBe(0)
    for (const row of await db.select().from(messages)) {
      expect(row.text).toBeNull()
      expect(decrypt({ encrypted: row.textEncrypted!, iv: row.textIv!, authTag: row.textTag! })).toBe(`synthetic ${row.messageId}`)
    }
  })

  it("clears matching copies but preserves partial and disagreeing copies", async () => {
    const owner = await fixture()
    const sealed = encrypt("matching")
    const cipher = { textEncrypted: sealed.encrypted, textIv: sealed.iv, textTag: sealed.authTag }
    await db.insert(messages).values([
      { ...owner, messageId: 1, text: "matching", ...cipher },
      { ...owner, messageId: 2, text: "different", ...cipher },
      { ...owner, messageId: 3, text: "partial", textEncrypted: sealed.encrypted },
    ])
    expect(await backfillMessageTextBatch({ apply: true })).toMatchObject({ migrated: 1, conflicts: 2 })
    expect((await db.select().from(messages).where(eq(messages.messageId, 2)))[0]!.text).toBe("different")
    expect((await db.select().from(messages).where(eq(messages.messageId, 3)))[0]!.text).toBe("partial")
  })

  it("does not overwrite an edit committed by a concurrent writer", async () => {
    const owner = await fixture()
    const [row] = await db.insert(messages).values({ ...owner, messageId: 1, text: "old" }).returning()
    let locked!: () => void
    let release!: () => void
    const acquired = new Promise<void>((resolve) => { locked = resolve })
    const unblock = new Promise<void>((resolve) => { release = resolve })
    const writer = db.transaction(async (tx) => {
      await tx.select().from(messages).where(eq(messages.globalId, row!.globalId)).for("update")
      locked()
      await unblock
      const sealed = encrypt("new edit")
      await tx.update(messages).set({ text: null, textEncrypted: sealed.encrypted, textIv: sealed.iv, textTag: sealed.authTag, rev: 1 })
        .where(eq(messages.globalId, row!.globalId))
    })
    await acquired
    let finished = false
    const backfill = backfillMessageTextBatch({ apply: true }).then((result) => { finished = true; return result })
    await Bun.sleep(20)
    expect(finished).toBe(false)
    release()
    await writer
    await backfill
    const [stored] = await db.select().from(messages).where(eq(messages.globalId, row!.globalId))
    expect(stored!.rev).toBe(1)
    expect(decrypt({ encrypted: stored!.textEncrypted!, iv: stored!.textIv!, authTag: stored!.textTag! })).toBe("new edit")
  })
})
