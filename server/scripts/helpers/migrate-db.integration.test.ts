import { afterAll, beforeAll, expect, test } from "bun:test"
import { copyFile, mkdir, mkdtemp, readFile, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { resolve } from "node:path"
import postgres from "postgres"
import { setupTestDatabase, teardownTestDatabase } from "../../src/__tests__/database"
import { createTestEnvironment } from "../test-environment"

beforeAll(setupTestDatabase)
afterAll(teardownTestDatabase)

const runMigrator = (cwd = resolve(import.meta.dir, "../..")) =>
  Bun.spawn({
    cmd: [process.execPath, "--no-env-file", resolve(import.meta.dir, "../migrate.ts")],
    cwd,
    env: createTestEnvironment(process.env, process.env.DATABASE_URL!),
    stdout: "ignore",
    stderr: "ignore",
  })

test("a concurrent migration fails before writing and can run after the owner releases", async () => {
  const client = postgres(process.env.DATABASE_URL!, { max: 1 })
  try {
    await client.begin(async (transaction) => {
      await transaction`select pg_advisory_xact_lock(${0x496e6c696e65}::bigint)`
      const [before] = await transaction<{ count: string }[]>`select count(*) from drizzle._migrations`
      expect(await runMigrator().exited).toBe(1)
      const [after] = await transaction<{ count: string }[]>`select count(*) from drizzle._migrations`
      expect(after?.count).toBe(before?.count)
    })
    expect(await runMigrator().exited).toBe(0)
  } finally {
    await client.end({ timeout: 2 })
  }
})

test("lock and DDL share a backend; losing it rolls back both schema and journal", async () => {
  const fixture = await mkdtemp(resolve(tmpdir(), "inline-migration-atomicity-"))
  const folder = resolve(fixture, "drizzle")
  await mkdir(resolve(folder, "meta"), { recursive: true })
  const source = resolve(import.meta.dir, "../../drizzle")
  const journal = JSON.parse(await readFile(resolve(source, "meta/_journal.json"), "utf8")) as {
    entries: { idx: number; version: string; when: number; tag: string; breakpoints: boolean }[]
  }
  for (const entry of journal.entries)
    await copyFile(resolve(source, `${entry.tag}.sql`), resolve(folder, `${entry.tag}.sql`))
  const previous = journal.entries.at(-1)!
  journal.entries.push({ ...previous, idx: previous.idx + 1, when: previous.when + 1, tag: "atomicity_probe" })
  await writeFile(resolve(folder, "meta/_journal.json"), JSON.stringify(journal))
  const sqlFile = resolve(folder, "atomicity_probe.sql")
  await writeFile(
    sqlFile,
    "CREATE TABLE migration_atomicity_probe (id integer);\n--> statement-breakpoint\nSELECT pg_sleep(10);",
  )
  const client = postgres(process.env.DATABASE_URL!, { max: 1 })
  const child = runMigrator(fixture)
  try {
    let pid: number | undefined
    const deadline = Date.now() + 5_000
    while (Date.now() < deadline && child.exitCode === null) {
      const [row] = await client<{ pid: number }[]>`
        select pid from pg_stat_activity
        where datname = current_database() and application_name = 'inline-migrator'
          and state = 'active' and query like '%pg_sleep(10)%'
      `
      if (row) {
        pid = row.pid
        break
      }
      await Bun.sleep(20)
    }
    expect(pid).toBeDefined()
    const [lock] = await client<{ owned: boolean }[]>`
      select exists(select 1 from pg_locks where pid = ${pid!} and locktype = 'advisory' and granted) as owned
    `
    expect(lock?.owned).toBe(true)
    await client`select pg_terminate_backend(${pid!})`
    expect(await child.exited).toBe(1)
    const [state] = await client<{ marker: string | null; head: string }[]>`
      select to_regclass('public.migration_atomicity_probe') as marker,
        (select max(created_at)::text from drizzle._migrations) as head
    `
    expect(state?.marker).toBeNull()
    expect(state?.head).toBe(String(previous.when))
    await writeFile(sqlFile, `CREATE TABLE migration_atomicity_probe AS SELECT
      current_setting('lock_timeout') AS lock_timeout,
      current_setting('statement_timeout') AS statement_timeout,
      current_setting('idle_in_transaction_session_timeout') AS idle_timeout;`)
    expect(await runMigrator(fixture).exited).toBe(0)
    const [timeouts] = await client`select * from migration_atomicity_probe`
    expect(timeouts).toEqual({ lock_timeout: "5s", statement_timeout: "30s", idle_timeout: "15s" })
  } finally {
    if (child.exitCode === null) child.kill("SIGKILL")
    await child.exited
    await client.end({ timeout: 2 })
  }
}, 15_000)
