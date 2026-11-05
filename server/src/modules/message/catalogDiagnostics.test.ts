import { describe, expect, test } from "bun:test"
import { CatalogDiagnostics, startCatalogDiagnostics } from "./catalogDiagnostics"
import { countTransferWork, recordSqlStatement } from "@in/server/modules/transfers/trace"

const result = { chats: [{ title: "private chat" }], dialogs: [], messages: [{ message: "private message" }], users: [], spaces: [] }

describe("catalog diagnostics", () => {
  test("attributes concurrent SQL work without retaining results or adding work", async () => {
    let now = 0
    const diagnostics = new CatalogDiagnostics(() => now)
    let finish!: () => void
    const pending = diagnostics.observe({ clientType: "cli", version: 3, isBot: true, includeSubthreads: true }, async (work) => {
      recordSqlStatement()
      await new Promise<void>((resolve) => { finish = resolve })
      work.candidateChats = 3
      work.preparationCandidates = 1
      work.prepareMs = 20
      work.snapshotMs = 580
      recordSqlStatement()
      return result
    })
    const nested = await countTransferWork(() => diagnostics.observe({ clientType: "macos", version: 2, isBot: false, includeSubthreads: false }, async () => {
      recordSqlStatement()
      recordSqlStatement()
      now = 200
      return result
    }))
    expect(nested.counters.sqlStatements).toBe(2)
    expect(nested.value).toBe(result)
    expect(diagnostics.drain()).toEqual([{
      client: "macos", carrier: "v2", account: "human", includeSubthreads: false,
      completed: 1, failed: 0, totalMs: 200, maxMs: 200, atLeast500Ms: 0,
      sqlStatements: 2, prepareMs: 0, snapshotMs: 0, candidateChats: 0, preparationCandidates: 0,
      returnedChats: 1, returnedDialogs: 0, returnedMessages: 1, returnedUsers: 0, returnedSpaces: 0,
    }])
    now = 600
    finish()
    expect(await pending).toBe(result)
    const rows = diagnostics.drain()
    expect(rows).toEqual([{
      client: "cli", carrier: "v3", account: "bot", includeSubthreads: true,
      completed: 1, failed: 0, totalMs: 600, maxMs: 600, atLeast500Ms: 1,
      sqlStatements: 2, prepareMs: 20, snapshotMs: 580, candidateChats: 3, preparationCandidates: 1,
      returnedChats: 1, returnedDialogs: 0, returnedMessages: 1, returnedUsers: 0, returnedSpaces: 0,
    }])
    expect(JSON.stringify(rows)).not.toContain("private")
  })

  test("keeps cohorts finite and rethrows original errors without logging their contents", async () => {
    const diagnostics = new CatalogDiagnostics()
    const failure = new Error("sensitive SQL bindings")
    for (let i = 0; i < 100; i++) {
      await expect(diagnostics.observe({ clientType: `untrusted-${i}`, version: i + 10, includeSubthreads: false }, async () => {
        recordSqlStatement()
        throw failure
      })).rejects.toBe(failure)
    }
    const rows = diagnostics.drain()
    expect(rows).toHaveLength(1)
    expect(rows[0]).toMatchObject({ client: "unknown", carrier: "unknown", account: "unknown", completed: 100, failed: 100, sqlStatements: 100, returnedChats: 0 })
    expect(JSON.stringify(rows)).not.toContain("untrusted")
    expect(JSON.stringify(rows)).not.toContain("sensitive")
  })

  test("flushes pending cohorts at shutdown even when the sink fails", async () => {
    const diagnostics = new CatalogDiagnostics()
    await diagnostics.observe({ clientType: "ios", includeSubthreads: false }, async () => result)
    await diagnostics.observe({ clientType: "cli", includeSubthreads: true }, async () => result)
    let emitted = 0
    const stop = startCatalogDiagnostics(() => { emitted++; throw new Error("sink unavailable") }, diagnostics)
    expect(stop).not.toThrow()
    expect(emitted).toBe(2)
    expect(diagnostics.drain()).toEqual([])
  })
})
