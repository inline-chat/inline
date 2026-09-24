import { expect, test } from "bun:test"
import { sql } from "drizzle-orm"
import { db, closeDb, initDb } from "@in/server/db"
import { setupTestLifecycle } from "../database"
import { createWireProxy } from "./wire"
import { measureOperation } from "./measure"

setupTestLifecycle()

test("real Drizzle queries expose protocol exchanges independently of SQL command counts", async () => {
  const direct = process.env["DATABASE_URL"]!
  const url = new URL(direct)
  const proxy = await createWireProxy({ host: url.hostname, port: Number(url.port || 5432) }, 0)
  url.hostname = "127.0.0.1"
  url.port = String(proxy.port)
  await closeDb()
  initDb(url.toString())
  try {
    await db.execute(sql`select ${1}::int as value`)
    const sample = await measureOperation(db.$client.options, async () => {
      const result = await db.execute(sql`select ${2}::int as value`)
      expect(result[0]?.["value"]).toBe(2)
    }, async () => {}, proxy)
    expect(sample.sql.commands).toBe(1)
    expect(sample.sql.catalogCommands).toBe(0)
    // Drizzle currently calls unsafe() without per-query prepare:true. Its
    // Describe/Flush and Bind/Execute/Sync produce two exchange boundaries.
    // A future driver optimization may reduce this to one, never to zero.
    expect(sample.wire!.exchangeBoundaries).toBeGreaterThanOrEqual(1)
    expect(sample.wire!.exchangeBoundaries).toBeLessThanOrEqual(2)
    expect(sample.wire!.frames["S"]).toBe(1)
    expect(sample.wire!.clientBytes).toBeGreaterThan(0)
    expect(sample.wire!.serverBytes).toBeGreaterThan(0)
    proxy.setDelay(3)
    const delayed = await measureOperation(db.$client.options, async () => { await db.execute(sql`select 1`) }, async () => {}, proxy)
    expect(delayed.sql.commands).toBe(1)
    expect(delayed.wire!.exchangeBoundaries).toBe(1)
    expect(delayed.operationMs).toBeGreaterThan(0)
  } finally {
    await closeDb()
    await proxy.close()
    initDb(direct)
  }
})
