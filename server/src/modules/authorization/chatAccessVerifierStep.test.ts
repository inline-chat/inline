import { describe, expect, test } from "bun:test"
import { eq, sql } from "drizzle-orm"
import { setupTestLifecycle, testUtils } from "@in/server/__tests__/setup"
import { db } from "@in/server/db"
import * as schema from "@in/server/db/schema"
import { verifyChatAccess, verifyChatAccessStep } from "./chatAccessVerifier"

const state = async () => {
  const [row] = await db.select().from(schema.chatAccessState)
  return row
}

/** Three home threads with one participant each, backfilled. */
const seed = async () => {
  const owner = await testUtils.createUser("verify-step-owner@example.com")
  const chats = []
  for (const title of ["One", "Two", "Three"]) {
    const chat = await testUtils.createChat(null, title, "thread", false, owner.id)
    if (!chat) throw new Error("Chat not created")
    await testUtils.addParticipant(chat.id, owner.id)
    chats.push(chat)
  }
  await verifyChatAccess()
  return { owner, chatIds: chats.map((chat) => chat.id).sort((a, b) => a - b) }
}

describe("shared chat access verification step", () => {
  setupTestLifecycle()

  test("servers share one pass: each step repairs the next batch, then orphans, then idles until the interval", async () => {
    const { owner, chatIds } = await seed()
    const [first, second, third] = chatIds as [number, number, number]
    // Drift in the second batch and an orphaned row.
    await db.delete(schema.chatAccess).where(eq(schema.chatAccess.chatId, second))
    await db.insert(schema.chatAccess).values({ chatId: third + 1_000_000, userId: owner.id })
    await db.update(schema.chatAccessState).set({ verifyCursor: null, verifiedAt: null })

    const now = new Date()
    const options = { batchSize: 1, passIntervalMs: 60_000, now }
    const steps = []
    for (let index = 0; index < 10; index += 1) {
      const step = await verifyChatAccessStep(options)
      if (!step) break
      steps.push(step)
      if (step.passCompleted) break
    }

    expect(steps.map((step) => step.chats)).toEqual([...chatIds.map(() => 1), 0])
    expect(steps.reduce((sum, step) => sum + step.missing, 0)).toBe(1)
    expect(steps.find((step) => step.missing === 1)?.samples).toEqual([{ chatId: second, userId: owner.id, kind: "missing" }])
    expect(steps.at(-1)?.orphans).toBe(1)
    expect(await state()).toMatchObject({ verifyCursor: null, verifiedAt: now })

    // Inside the interval nothing runs; after it a new pass starts at the first chat.
    expect(await verifyChatAccessStep({ ...options, now: new Date(now.getTime() + 30_000) })).toBeNull()
    const restarted = await verifyChatAccessStep({ ...options, now: new Date(now.getTime() + 61_000) })
    expect(restarted?.chats).toBe(1)
    expect((await state())?.verifyCursor).toBe(first)
  })

  test("only one server takes a step at a time", async () => {
    await seed()
    await db.update(schema.chatAccessState).set({ verifyCursor: null, verifiedAt: null })

    let release!: () => void
    const held = new Promise<void>((resolve) => { release = resolve })
    let locked!: () => void
    const lockTaken = new Promise<void>((resolve) => { locked = resolve })
    const holder = db.transaction(async (tx) => {
      await tx.execute(sql`select pg_advisory_xact_lock(hashtextextended('inline:chat-access-verify', 0))`)
      locked()
      await held
    })
    await lockTaken
    try {
      expect(await verifyChatAccessStep({ batchSize: 1 })).toBeNull()
      expect((await state())?.verifyCursor).toBeNull()
    } finally {
      release()
      await holder
    }
    expect((await verifyChatAccessStep({ batchSize: 1 }))?.chats).toBe(1)
  })

  test("before the first backfill a step runs the whole-table pass and writes the marker", async () => {
    const owner = await testUtils.createUser("verify-step-backfill@example.com")
    const chat = await testUtils.createChat(null, "Backfill", "thread", false, owner.id)
    if (!chat) throw new Error("Chat not created")
    await testUtils.addParticipant(chat.id, owner.id)
    expect(await state()).toBeUndefined()

    const step = await verifyChatAccessStep({ batchSize: 1 })
    expect(step).toMatchObject({ backfill: true, passCompleted: true, missing: 1 })
    expect(await state()).toMatchObject({ verifyCursor: null })
    expect((await state())?.verifiedAt).toBeInstanceOf(Date)
  })
})
