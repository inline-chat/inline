import { afterAll, beforeAll, expect, test } from "bun:test"
import { mkdir, mkdtemp, readFile, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { resolve } from "node:path"
import postgres from "postgres"
import { setupTestDatabase, teardownTestDatabase } from "../../src/__tests__/database"
import { ONLINE_INDEXES, prebuildOnlineIndexes } from "./online-indexes"

beforeAll(setupTestDatabase)
afterAll(teardownTestDatabase)

const LOCK_KEY = 0x496e6c696e65
const source = resolve(import.meta.dir, "../../drizzle")

type Journal = { entries: { idx: number; version: string; when: number; tag: string; breakpoints: boolean }[] }

/** A migration folder whose journal treats `pending` tags as not yet applied. */
const fixtureFolder = async (extra: Journal["entries"] = [], pending: readonly string[] = []) => {
  const folder = await mkdtemp(resolve(tmpdir(), "inline-online-indexes-"))
  await mkdir(resolve(folder, "meta"), { recursive: true })
  const journal = JSON.parse(await readFile(resolve(source, "meta/_journal.json"), "utf8")) as Journal
  const entries = journal.entries.map((entry) =>
    pending.includes(entry.tag) ? { ...entry, when: entry.when + 1_000_000_000 } : entry,
  )
  await writeFile(resolve(folder, "meta/_journal.json"), JSON.stringify({ ...journal, entries: [...entries, ...extra] }))
  return folder
}

const probeEntry = { idx: 9_999, version: "7", when: 9_999_999_999_999, tag: "9999_online-probe", breakpoints: true }

const indexState = async (client: postgres.Sql, name: string) => {
  const [row] = await client<{ valid: boolean; definition: string }[]>`
    select indisvalid as valid, pg_get_indexdef(indexrelid) as definition
    from pg_index where indexrelid = to_regclass(${`public.${name}`})
  `
  return row
}

test("a pending migration's index is built online, an applied one's is skipped and a missing table defers", async () => {
  const client = postgres(process.env.DATABASE_URL!, { max: 1, onnotice: () => {} })
  try {
    await client`create table online_probe (id integer primary key, v integer)`
    await client`insert into online_probe select g, g % 7 from generate_series(1, 2000) g`
    const folder = await fixtureFolder([probeEntry])
    const first = (await readFile(resolve(source, "meta/_journal.json"), "utf8")).match(/"tag": "([^"]+)"/)![1]!
    const built = await prebuildOnlineIndexes(process.env.DATABASE_URL!, folder, LOCK_KEY, [
      { migration: probeEntry.tag, name: "online_probe_v_idx", sql: `CREATE INDEX CONCURRENTLY IF NOT EXISTS "online_probe_v_idx" ON "online_probe" ("v")` },
      { migration: first, name: "online_probe_id_idx", sql: `CREATE INDEX CONCURRENTLY IF NOT EXISTS "online_probe_id_idx" ON "online_probe" ("id")` },
      { migration: probeEntry.tag, name: "online_missing_idx", sql: `CREATE INDEX CONCURRENTLY IF NOT EXISTS "online_missing_idx" ON "online_missing" ("v")` },
    ])
    expect(built).toEqual(["online_probe_v_idx"])
    expect((await indexState(client, "online_probe_v_idx"))?.valid).toBe(true)
    expect(await indexState(client, "online_probe_id_idx")).toBeUndefined()
  } finally {
    await client`drop table if exists online_probe`
    await client.end({ timeout: 2 })
  }
})

test("an invalid index left by an interrupted build is replaced", async () => {
  const client = postgres(process.env.DATABASE_URL!, { max: 1, onnotice: () => {} })
  try {
    await client`create table online_retry (id integer primary key, v integer)`
    await client`insert into online_retry select g, 1 from generate_series(1, 100) g`
    // A failed concurrent build keeps its catalog entry, marked invalid.
    await client.unsafe(`CREATE UNIQUE INDEX CONCURRENTLY "online_retry_v_idx" ON "online_retry" ("v")`).catch(() => {})
    expect((await indexState(client, "online_retry_v_idx"))?.valid).toBe(false)
    const built = await prebuildOnlineIndexes(process.env.DATABASE_URL!, await fixtureFolder([probeEntry]), LOCK_KEY, [
      { migration: probeEntry.tag, name: "online_retry_v_idx", sql: `CREATE INDEX CONCURRENTLY IF NOT EXISTS "online_retry_v_idx" ON "online_retry" ("v")` },
    ])
    expect(built).toEqual(["online_retry_v_idx"])
    const state = await indexState(client, "online_retry_v_idx")
    expect(state?.valid).toBe(true)
    expect(state?.definition).not.toContain("UNIQUE")
  } finally {
    await client`drop table if exists online_retry`
    await client.end({ timeout: 2 })
  }
})

test("another migrator holding the lock stops the build", async () => {
  const holder = postgres(process.env.DATABASE_URL!, { max: 1 })
  try {
    await holder.begin(async (transaction) => {
      await transaction`select pg_advisory_xact_lock(${LOCK_KEY}::bigint)`
      await expect(prebuildOnlineIndexes(process.env.DATABASE_URL!, await fixtureFolder([probeEntry]), LOCK_KEY, [
        { migration: probeEntry.tag, name: "online_locked_idx", sql: `CREATE INDEX CONCURRENTLY IF NOT EXISTS "online_locked_idx" ON "messages" ("id")` },
      ])).rejects.toThrow("Another database migration is already running.")
    })
  } finally {
    await holder.end({ timeout: 2 })
  }
})

test("the global search indexes built online match the definitions 0176 verifies", async () => {
  const client = postgres(process.env.DATABASE_URL!, { max: 1, onnotice: () => {} })
  try {
    const migration = await readFile(resolve(source, "0176_global-message-search.sql"), "utf8")
    const expected = new Map(
      [...migration.matchAll(/\('(messages_[a-z_]+_idx)', '(CREATE INDEX [^']+)'\)/g)].map((match) => [match[1]!, match[2]!]),
    )
    expect([...expected.keys()].sort()).toEqual(ONLINE_INDEXES.map((index) => index.name).sort())
    for (const name of expected.keys()) await client.unsafe(`DROP INDEX "public"."${name}"`)
    const built = await prebuildOnlineIndexes(
      process.env.DATABASE_URL!,
      await fixtureFolder([], ["0176_global-message-search"]),
      LOCK_KEY,
    )
    expect(built.sort()).toEqual([...expected.keys()].sort())
    for (const [name, definition] of expected) {
      const state = await indexState(client, name)
      expect(state?.valid).toBe(true)
      expect(state?.definition).toBe(definition)
    }
  } finally {
    await client.end({ timeout: 2 })
  }
})
