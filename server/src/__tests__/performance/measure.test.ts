import { expect, test } from "bun:test"
import { Effect } from "effect"
import type postgres from "postgres"
import { assertQueryBudget, distribution, measureOperation, statementShape } from "./measure"
import { FrontendFrames, createWireProxy } from "./wire"
import { selectScenarios } from "./catalog"

function recorder() {
  const options: Pick<postgres.Options<{}>, "debug"> = { debug: false }
  const query = (statement: string, connection = 1) => {
    if (typeof options.debug === "function") options.debug(connection, statement, ["never-export-this-value"], [])
  }
  return { options, query }
}

test("counts real driver callbacks through drain, separating catalog and transaction work", async () => {
  const { options, query } = recorder()
  const sample = await measureOperation(options, async () => {
    query("select b.oid, b.typarray from pg_catalog.pg_type a left join pg_catalog.pg_type b on b.oid = a.typelem")
    query("begin")
    query("select * from messages where id = $1")
  }, async () => { query("commit"); query("select 'private-text'", 2) })
  expect(sample.sql.commands).toBe(4)
  expect(sample.sql.catalogCommands).toBe(1)
  expect(sample.sql.transactions).toBe(2)
  expect(sample.sql.connections).toBe(2)
  expect(sample.commandsBeforeReturn).toBe(2)
  expect(sample.settledMs).toBeGreaterThanOrEqual(sample.operationMs)
  expect(JSON.stringify(sample)).not.toContain("private-text")
  expect(JSON.stringify(sample)).not.toContain("never-export-this-value")
  expect(options.debug).toBe(false)
  expect(() => assertQueryBudget("fixture", sample, 3)).toThrow("exceed budget")
})

test("failed operations still drain, restore the observer, and cannot become successful samples", async () => {
  const { options, query } = recorder()
  const failure = new Error("operation failed")
  const background = new Error("background failed")
  let drained = false
  try {
    await measureOperation(options, async () => { query("select 1"); throw failure }, async () => { drained = true; throw background })
    throw new Error("Expected failure")
  } catch (error) {
    expect(error).toBeInstanceOf(AggregateError)
    expect((error as AggregateError).errors).toEqual([failure, background])
  }
  expect(drained).toBe(true)
  expect(options.debug).toBe(false)
  const sample = await measureOperation(options, async () => {}, async () => {})
  expect(() => assertQueryBudget("unobserved", sample, 10)).toThrow("no database commands observed")
})

test("overlapping captures fail instead of silently mixing attribution", async () => {
  const { options } = recorder()
  const gate = Promise.withResolvers<void>()
  const first = measureOperation(options, () => gate.promise, async () => {})
  try {
    await expect(measureOperation(options, async () => {}, async () => {})).rejects.toThrow("Overlapping")
  } finally { gate.resolve(); await first }
})

test("a broken wire observer cannot leave SQL instrumentation installed", async () => {
  const { options } = recorder()
  await expect(measureOperation(options, async () => {}, async () => {}, {
    reset() { throw new Error("broken meter") },
    snapshot() { throw new Error("unreachable") },
  })).rejects.toThrow("broken meter")
  expect(options.debug).toBe(false)
  await measureOperation(options, async () => {}, async () => {})
})

test("Effect scope finalizers belong to the operation's real lifetime", async () => {
  const { options, query } = recorder()
  const program = Effect.scoped(Effect.gen(function*() {
    yield* Effect.acquireRelease(Effect.sync(() => query("begin")), () => Effect.sync(() => query("commit")))
    yield* Effect.sync(() => query("select 1"))
  }))
  const sample = await measureOperation(options, () => Effect.runPromise(program), async () => {})
  expect(sample.commandsBeforeReturn).toBe(3)
  expect(sample.sql.transactions).toBe(2)
})

test("fingerprints coalesce literals without retaining statements", () => {
  expect(statementShape("select 'secret-one', 12")).toBe(statementShape("select 'secret-two', 54"))
  expect(statementShape("select $$private-one$$")).toBe(statementShape("select $$private-two$$"))
  expect(statementShape("select $tag$private-one$tag$")).toBe(statementShape("select $tag$private-two$tag$"))
  expect(statementShape("select 1")).not.toBe(statementShape("update messages set revision = 1"))
})

test("summary statistics refuse empty data and avoid tail claims for smoke samples", () => {
  expect(distribution([4, 1, 3, 2])).toEqual({ min: 1, median: 2.5, p95: null, max: 4 })
  expect(distribution(Array.from({ length: 20 }, (_, i) => i + 1)).p95).toBe(19)
  expect(() => distribution([])).toThrow()
  expect(() => distribution([NaN])).toThrow()
  expect(() => selectScenarios(["misspelled-path"])).toThrow("Unknown backend scenario")
  expect(() => selectScenarios([])).toThrow("at least one")
})

function frame(kind: string, payload = "") {
  const bytes = Buffer.alloc(5 + Buffer.byteLength(payload))
  bytes.writeUInt8(kind.charCodeAt(0))
  bytes.writeUInt32BE(bytes.length - 1, 1)
  bytes.write(payload, 5)
  return bytes
}

test("wire framing survives every fragmentation boundary and coalesced frames", () => {
  const startup = Buffer.alloc(8)
  startup.writeUInt32BE(8)
  startup.writeUInt32BE(196608, 4)
  const bytes = Buffer.concat([startup, frame("P", "do-not-retain-SQL"), frame("D", "statement"), frame("H"), frame("B", "private-bind-value"), frame("E"), frame("S")])
  for (let split = 0; split <= bytes.length; split++) {
    const frames: string[] = []
    const parser = new FrontendFrames((kind) => frames.push(kind))
    parser.accept(bytes.subarray(0, split))
    parser.accept(bytes.subarray(split))
    expect(frames).toEqual(["P", "D", "H", "B", "E", "S"])
  }
  const frames: string[] = []
  const parser = new FrontendFrames((kind) => frames.push(kind))
  for (const byte of bytes) parser.accept(Buffer.from([byte]))
  expect(frames).toHaveLength(6)
})

test("invalid frame lengths and remote proxy targets fail closed", async () => {
  const parser = new FrontendFrames(() => {})
  expect(() => parser.accept(Buffer.from([0, 0, 0, 0]))).toThrow("Invalid")
  await expect(createWireProxy({ host: "example.com", port: 5432 }, 5)).rejects.toThrow("loopback")
  await expect(createWireProxy({ host: "127.0.0.1", port: 5432 }, NaN)).rejects.toThrow("RTT")
})
