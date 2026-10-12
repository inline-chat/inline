import { describe, expect, test } from "bun:test"
import { PgDialect } from "drizzle-orm/pg-core"
import { DatabaseDiagnostics, startDatabaseDiagnostics } from "./databaseDiagnostics"
import { effectiveChatAccessSql } from "../modules/authorization/chatAccessProjection"

describe("database diagnostics", () => {
  test("preserves results and tracks concurrent work across reporting windows", async () => {
    let now = 0
    const diagnostics = new DatabaseDiagnostics(() => now)
    let finish!: (value: number) => void
    const pending = diagnostics.observe("access.sync.replay", 6, () => new Promise<number>((resolve) => { finish = resolve }))
    now = 200
    await diagnostics.observe("access.sync.replay", 2, async () => { now = 350; return 1 })
    expect(diagnostics.drain()).toEqual([{
      operation: "access.sync.replay", completed: 1, failed: 0,
      totalMs: 150, maxMs: 150, atLeast100Ms: 1, atLeast500Ms: 0,
      workItems: 2, inFlight: 1, peakInFlight: 2,
    }])
    now = 600
    finish(42)
    expect(await pending).toBe(42)
    expect(diagnostics.drain()).toEqual([{
      operation: "access.sync.replay", completed: 1, failed: 0,
      totalMs: 600, maxMs: 600, atLeast100Ms: 1, atLeast500Ms: 1,
      workItems: 6, inFlight: 0, peakInFlight: 1,
    }])
    expect(diagnostics.drain()).toEqual([])
  })

  test("rethrows the original failure without retaining its sensitive content", async () => {
    const diagnostics = new DatabaseDiagnostics()
    const error = new Error("private SQL bindings")
    try {
      await diagnostics.observe("access.authorization", 1, () => { throw error })
      throw new Error("expected operation to fail")
    } catch (caught) { expect(caught).toBe(error) }
    const rows = diagnostics.drain()
    expect(rows[0]).toMatchObject({ completed: 1, failed: 1, inFlight: 0 })
    expect(JSON.stringify(rows)).not.toContain(error.message)
  })

  test("reporter failure does not escape shutdown or prevent other rows being reported", () => {
    const diagnostics = new DatabaseDiagnostics()
    diagnostics.record("replay.user.total", 50, 100)
    diagnostics.record("transaction.admission", 5)
    let emitted = 0
    const stop = startDatabaseDiagnostics(() => { emitted += 1; throw new Error("sink unavailable") }, diagnostics)
    expect(stop).not.toThrow()
    expect(emitted).toBe(2)
    expect(diagnostics.drain()).toEqual([])
  })

  test("attribution adds only a fixed comment and preserves query bindings", () => {
    const dialect = new PgDialect()
    const query = dialect.sqlToQuery(effectiveChatAccessSql([125, 250], [375], "sync.replay"))
    expect(query.sql).toContain("/*application='inline-server',operation='chat_access',source='sync.replay'*/")
    expect(query.sql).not.toContain("125")
    expect(query.sql).not.toContain("250")
    expect(query.sql).not.toContain("375")
    expect(query.params).toContain(125)
    expect(query.params).toContain(375)
  })
})
