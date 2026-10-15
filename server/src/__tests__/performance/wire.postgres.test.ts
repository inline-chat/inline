import { expect, test } from "bun:test"
import { sql } from "drizzle-orm"
import { makeDatabaseClients } from "@in/server/db/connectionPolicy"
import { drizzle } from "drizzle-orm/postgres-js"
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
  // This dedicated direct fixture qualifies the opt-in explicitly; production
  // uses a role default because PgBouncer rejects this startup parameter.
  url.searchParams.set("plan_cache_mode", "force_custom_plan")
  const clients = makeDatabaseClients(url.toString(), { INLINE_DATABASE_PREPARED_QUERIES: "all-custom" })
  const db = drizzle(clients.queryClient)
  try {
    await clients.validateStartup()
    await db.execute(sql`select ${0}::int as value`)
    await db.execute(sql`select ${1}::int as value`)
    const sample = await measureOperation(db.$client.options, async () => {
      const result = await db.execute(sql`select ${2}::int as value`)
      expect(result[0]?.["value"]).toBe(2)
    }, async () => {}, proxy)
    expect(sample.sql.commands).toBe(1)
    expect(sample.sql.catalogCommands).toBe(0)
    // Warm parameterized Drizzle reads must skip Describe/Flush, not merely
    // keep the SQL command count unchanged.
    expect(sample.wire!.exchangeBoundaries).toBe(1)
    expect(sample.wire!.frames["H"] ?? 0).toBe(0)
    expect(sample.wire!.frames["S"]).toBe(1)
    expect(sample.wire!.clientBytes).toBeGreaterThan(0)
    expect(sample.wire!.serverBytes).toBeGreaterThan(0)
    proxy.setDelay(3)
    const delayed = await measureOperation(db.$client.options, async () => { await db.execute(sql`select 1`) }, async () => {}, proxy)
    expect(delayed.sql.commands).toBe(1)
    expect(delayed.wire!.exchangeBoundaries).toBe(1)
    expect(delayed.operationMs).toBeGreaterThan(0)
  } finally {
    await clients.close()
    await proxy.close()
  }
})
