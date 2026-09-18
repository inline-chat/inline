import { describe, expect, test } from "bun:test"
import { eq, sql } from "drizzle-orm"
import { db, schema } from "@in/server/db"
import { setupTestLifecycle } from "@in/server/__tests__/database"
import { InlineProtocolReplayRepository } from "@in/server/db/models/inlineProtocol"
import { makeReplayResultCipher, type ReplayResultCipher } from "./replayCipher"
import { makeInlineProtocolReplayRepository } from "./replay"

const cipher = makeReplayResultCipher({ activeId: "test", keys: new Map([["test", new Uint8Array(32).fill(1)]]) })
const repository = (encryptWrites = true, override: ReplayResultCipher = cipher) =>
  new InlineProtocolReplayRepository({ cipher: override, encryptWrites })
const identity = (messageId = 1n) => ({ authKeyId: new Uint8Array(8).fill(2), protocolSessionId: 3n, messageId })
const body = Buffer.from("recognizable synthetic private replay result")
const claim = (messageId = 1n) => ({ ...identity(messageId), authenticatedBody: Uint8Array.of(7), ttlMs: 1 })
const rows = () => db.select().from(schema.inlineProtocolRequests).orderBy(schema.inlineProtocolRequests.messageId)

describe("durable encrypted replay results", () => {
  setupTestLifecycle()

  test("forward migration preserves old rows and allows envelope overhead without widening the plaintext limit", async () => {
    const migration = await Bun.file(new URL("../../../drizzle/0148_replay-result-encryption.sql", import.meta.url)).text()
    await db.transaction(async (tx) => {
      await tx.execute(sql`create temporary table inline_protocol_requests (
        result_body bytea,
        constraint inline_protocol_requests_result_length check (result_body is null or octet_length(result_body) <= 16777216)
      ) on commit drop`)
      await tx.execute(sql`insert into inline_protocol_requests (result_body) values (null), (${body})`)
      for (const statement of migration.split("--> statement-breakpoint")) await tx.execute(sql.raw(statement))
      const rows = await tx.execute<{ result_format: number; result_body: Buffer | null }>(sql`select * from inline_protocol_requests`)
      expect(rows.map((row) => row.result_format)).toEqual([0, 0])
      expect(rows[1]!.result_body).toEqual(body)
      const ciphertext = cipher.encrypt(identity(), Buffer.alloc(16 * 1024 * 1024))
      await tx.execute(sql`insert into inline_protocol_requests (result_body, result_format) values (${ciphertext}, 1)`)
      await expect(tx.transaction(async (nested) => {
        await nested.execute(sql`insert into inline_protocol_requests (result_body, result_format) values (${ciphertext}, 0)`)
      })).rejects.toThrow()
      await expect(tx.transaction(async (nested) => {
        await nested.execute(sql`insert into inline_protocol_requests (result_body, result_format) values (null, 1)`)
      })).rejects.toThrow()
    })
  })

  test("preserves duplicates, digest checks, restart reads, and adapter replacement semantics", async () => {
    const writer = repository()
    expect(await writer.claim(claim())).toEqual({ kind: "claimed" })
    expect(await writer.complete({ ...identity(), resultBody: body })).toBeTrue()
    expect(await writer.complete({ ...identity(), resultBody: Buffer.from("must not win") })).toBeFalse()
    const [row] = await rows()
    expect(row!.resultFormat).toBe(1)
    expect(row!.resultBody!.includes(body)).toBeFalse()
    expect(await repository().claim(claim())).toEqual({ kind: "completed", resultBody: body })
    expect(await writer.claim({ ...claim(), authenticatedBody: Uint8Array.of(8) })).toEqual({ kind: "digest_mismatch" })
    const adapter = makeInlineProtocolReplayRepository(repository(false))
    try {
      expect(await adapter.complete({ authKeyId: identity().authKeyId, sessionId: 3n, messageId: 1n, resultBody: Buffer.from("late") }))
        .toEqual({ kind: "superseded", resultBody: body })
      await adapter.forgetAnswer({ authKeyId: identity().authKeyId, sessionId: 3n, messageId: 1n, forgottenResultBody: Buffer.from("forgotten") })
      expect(await repository().result(identity())).toEqual(Buffer.from("forgotten"))
      expect((await rows())[0]!.resultFormat).toBe(1)
    } finally { adapter.close() }
  })

  test("stages compatible readers before writers and migrates only completed rows in bounded batches", async () => {
    const legacy = new InlineProtocolReplayRepository()
    for (const id of [1n, 2n, 3n]) await legacy.claim(claim(id))
    for (const id of [1n, 2n]) await legacy.complete({ ...identity(id), resultBody: body })
    expect(await repository(false).result(identity())).toEqual(body)
    expect(await repository().encryptCompletedBatch(1)).toBe(1)
    expect((await rows()).map((row) => row.resultFormat)).toEqual([1, 0, 0])
    expect(await repository(false).result(identity())).toEqual(body)
    expect(await repository().encryptCompletedBatch(1)).toBe(1)
    expect(await repository().encryptCompletedBatch(1)).toBe(0)
    expect(await repository().claim(claim(3n))).toEqual({ kind: "in_flight" })
    expect(await repository().replaceResult({ ...identity(3n), resultBody: body })).toBeFalse()
    await expect(legacy.result(identity())).rejects.toThrow()
    await expect(repository(false).encryptCompletedBatch()).rejects.toThrow()
  })

  test("fails closed on row swaps, tampering and unavailable keys without reclaiming execution", async () => {
    for (const id of [1n, 2n]) {
      await repository().claim(claim(id))
      await repository().complete({ ...identity(id), resultBody: body })
    }
    const encrypted = (await rows())[0]!.resultBody!
    await db.update(schema.inlineProtocolRequests).set({ resultBody: encrypted }).where(eq(schema.inlineProtocolRequests.messageId, 2n))
    await expect(repository().result(identity(2n))).rejects.toThrow()
    await expect(repository().claim(claim(2n))).rejects.toThrow()
    await expect(repository().replaceResult({ ...identity(2n), resultBody: body })).rejects.toThrow()
    const broken = Buffer.from(encrypted)
    broken[broken.length - 1] = broken[broken.length - 1]! ^ 1
    await db.update(schema.inlineProtocolRequests).set({ resultBody: broken }).where(eq(schema.inlineProtocolRequests.messageId, 1n))
    await expect(repository().claim(claim())).rejects.toThrow()
    expect(await repository().complete({ ...identity(), resultBody: body })).toBeFalse()
    expect((await rows()).length).toBe(2)
  })

  test("rolls back an interrupted batch and safely resumes", async () => {
    const legacy = repository(false)
    for (const id of [1n, 2n]) {
      await legacy.claim(claim(id))
      await legacy.complete({ ...identity(id), resultBody: body })
    }
    let writes = 0
    const failing = repository(true, { ...cipher, encrypt: (...args) => {
      if (++writes === 2) throw new Error("interrupted")
      return cipher.encrypt(...args)
    } })
    await expect(failing.encryptCompletedBatch(2)).rejects.toThrow()
    expect((await rows()).map((row) => row.resultFormat)).toEqual([0, 0])
    expect(await repository().encryptCompletedBatch(2)).toBe(2)
  })

  test("serializes migration with concurrent replacement and completion", async () => {
    const legacy = repository(false)
    await legacy.claim(claim())
    await legacy.complete({ ...identity(), resultBody: body })
    await legacy.claim(claim(2n))
    await Promise.all([
      repository().encryptCompletedBatch(2),
      repository().replaceResult({ ...identity(), resultBody: Buffer.from("replacement") }),
      repository().complete({ ...identity(2n), resultBody: body }),
    ])
    expect(await repository().result(identity())).toEqual(Buffer.from("replacement"))
    expect(await repository().result(identity(2n))).toEqual(body)
    expect((await rows()).map((row) => row.resultFormat)).toEqual([1, 1])
  })
})
