import { afterAll, beforeAll, describe, expect, test } from "bun:test"
import { mkdtemp, writeFile } from "node:fs/promises"
import { join } from "node:path"
import { createServer } from "node:net"
import postgres from "postgres"
import { drizzle } from "drizzle-orm/postgres-js"
import { sql } from "drizzle-orm"
import { makeDatabaseClients } from "./connectionPolicy"

// Opt-in infrastructure by availability, not by credentials: these tests create
// their own loopback-only database and never consume a configured DATABASE_URL.
const initdb = Bun.which("initdb")
const pgCtl = Bun.which("pg_ctl")
const pgbouncer = Bun.which("pgbouncer")
const available = Boolean(initdb && pgCtl && pgbouncer)
const suite = available ? describe : describe.skip

const freePort = () => new Promise<number>((resolve, reject) => {
  const server = createServer()
  server.on("error", reject)
  server.listen(0, "127.0.0.1", () => {
    const address = server.address()
    if (!address || typeof address === "string") { server.close(); reject(new Error("No local port")); return }
    server.close(() => resolve(address.port))
  })
})

suite("real transaction pooling safety (requires local PostgreSQL and PgBouncer binaries)", () => {
  let directory: string
  let admin: ReturnType<typeof postgres> | undefined
  let clients: ReturnType<typeof makeDatabaseClients> | undefined
  let bouncer: ReturnType<typeof Bun.spawn> | undefined
  let databaseStarted = false
  let directUrl: string
  let pooledUrl: string

  const run = async (cmd: string[]) => {
    const child = Bun.spawn(cmd, { env: { ...process.env, LC_ALL: "C" }, stdout: "pipe", stderr: "pipe" })
    // Consume both pipes; expose no URLs or credentials on subprocess failure.
    await Promise.all([new Response(child.stdout).text(), new Response(child.stderr).text()])
    if (await child.exited !== 0) throw new Error(`Local fixture command failed: ${cmd[0]}`)
  }

  beforeAll(async () => {
    // macOS's default TMPDIR can exceed PostgreSQL's Unix socket path limit.
    directory = await mkdtemp("/tmp/inline-pgbouncer-test-")
    const port = await freePort()
    const pooledPort = await freePort()
    const data = join(directory, "data")
    await run([initdb!, "-D", data, "-U", "fixture_admin", "-A", "trust", "--no-locale"])
    await run([pgCtl!, "-D", data, "-l", join(directory, "postgres.log"), "-o", `-h 127.0.0.1 -p ${port} -k ${directory}`, "-w", "start"])
    databaseStarted = true
    admin = postgres(`postgres://fixture_admin@127.0.0.1:${port}/postgres`, { max: 1 })
    await admin`create role fixture_app login`
    await admin`alter role fixture_app set statement_timeout = '30s'`
    await admin`alter role fixture_app set lock_timeout = '5s'`
    await admin`alter role fixture_app set idle_in_transaction_session_timeout = '15s'`
    await admin`create role fixture_unsafe login`
    await admin`create table public.pooling_fixture (id int primary key)`
    await admin`grant select, insert on public.pooling_fixture to fixture_app`
    await writeFile(join(directory, "users.txt"), '"fixture_app" ""\n"fixture_unsafe" ""\n')
    await writeFile(join(directory, "pgbouncer.ini"), `[databases]\npostgres = host=127.0.0.1 port=${port} dbname=postgres\n[pgbouncer]\nlisten_addr = 127.0.0.1\nlisten_port = ${pooledPort}\nunix_socket_dir = ${directory}\nauth_type = trust\nauth_file = ${join(directory, "users.txt")}\npool_mode = transaction\ndefault_pool_size = 2\nmax_client_conn = 30\nmax_prepared_statements = 200\nlogfile = ${join(directory, "pgbouncer.log")}\npidfile = ${join(directory, "pgbouncer.pid")}\n`)
    bouncer = Bun.spawn([pgbouncer!, join(directory, "pgbouncer.ini")], { stdout: "ignore", stderr: "ignore" })
    const deadline = Date.now() + 5_000
    while (true) {
      if (bouncer.exitCode !== null || Date.now() >= deadline) throw new Error("Local PgBouncer did not become ready")
      try {
        const socket = await Bun.connect({ hostname: "127.0.0.1", port: pooledPort, socket: { data() {} } })
        socket.end()
        break
      } catch { await Bun.sleep(20) }
    }
    directUrl = `postgres://fixture_app@127.0.0.1:${port}/postgres`
    pooledUrl = `postgres://fixture_app@127.0.0.1:${pooledPort}/postgres`
    clients = makeDatabaseClients(pooledUrl, { DATABASE_CONNECTION_MODE: "pgbouncer", DATABASE_DIRECT_URL: directUrl })
    await clients.validateStartup()
  }, 30_000)

  afterAll(async () => {
    await clients?.close()
    await admin?.end({ timeout: 2 })
    if (bouncer) { bouncer.kill(); await bouncer.exited }
    if (databaseStarted) await run([pgCtl!, "-D", join(directory, "data"), "-m", "fast", "-w", "stop"])
    // Retain the isolated fixture and logs for diagnosis; no destructive cleanup.
  }, 15_000)

  test("startup rejects a role without timeout defaults", async () => {
    const unsafe = makeDatabaseClients(pooledUrl.replace("fixture_app", "fixture_unsafe"), {
      DATABASE_CONNECTION_MODE: "pgbouncer", DATABASE_DIRECT_URL: directUrl,
    })
    try { await expect(unsafe.validateStartup()).rejects.toThrow("startup qualification failed") }
    finally { await unsafe.close() }
  })

  test("prepared queries reuse two server connections without losing role defaults", async () => {
    const results = await Promise.all(Array.from({ length: 40 }, (_, value) => clients!.queryClient.begin(async (tx) => {
      const rows = await tx`select ${value}::int as value, pg_backend_pid() as pid, current_setting('statement_timeout') as timeout`
      await tx`select pg_sleep(0.005)`
      return rows[0]!
    })))
    expect(results.map((r) => r["value"])).toEqual(Array.from({ length: 40 }, (_, i) => i))
    expect(new Set(results.map((r) => r["pid"])).size).toBe(2)
    expect(results.every((r) => r["timeout"] === "30s")).toBe(true)
  })

  test("transaction-local timeout cancels and does not leak to the next borrower", async () => {
    await expect(clients!.queryClient.begin(async (tx) => {
      await tx`set local statement_timeout = '75ms'`
      await tx`select pg_sleep(1)`
    })).rejects.toMatchObject({ code: "57014" })
    await clients!.validateStartup()
  })

  test("direct health connection retains its stricter timeout and recovers", async () => {
    const settings = await clients!.healthClient`select current_setting('statement_timeout') as statement, current_setting('lock_timeout') as lock, current_setting('idle_in_transaction_session_timeout') as idle`
    expect(settings[0]).toMatchObject({ statement: "1500ms", lock: "500ms", idle: "2s" })
    await expect(Promise.resolve(clients!.healthClient`select pg_sleep(3)`)).rejects.toMatchObject({ code: "57014" })
    const recovered = await clients!.healthClient`select 1 as value`
    expect(recovered[0]!["value"]).toBe(1)
  }, 5_000)

  test("rollback discards writes and returns a reusable pooled connection", async () => {
    await expect(clients!.queryClient.begin(async (tx) => {
      await tx`insert into pooling_fixture values (1)`
      throw new Error("fixture rollback")
    })).rejects.toThrow("fixture rollback")
    const rows = await clients!.queryClient`select count(*)::int as count from pooling_fixture`
    expect(rows[0]!["count"]).toBe(0)
  })

  test("Drizzle transactions and transaction-scoped advisory locks work through the pool", async () => {
    const db = drizzle(clients!.queryClient)
    await db.transaction(async (tx) => {
      await tx.execute(sql`select pg_advisory_xact_lock(74623)`)
      await tx.execute(sql`insert into pooling_fixture values (2)`)
      expect((await tx.execute(sql`select count(*)::int as count from pooling_fixture`))[0]!["count"]).toBe(1)
    })
    expect((await db.execute(sql`select count(*)::int as count from pooling_fixture`))[0]!["count"]).toBe(1)
  })

  test("client cancellation reaches a running pooled query and the pool recovers", async () => {
    const query = clients!.queryClient`select pg_sleep(5) /* inline_pool_cancel_fixture */`.execute()
    const result = Promise.resolve(query).catch((error: unknown) => error)
    const deadline = Date.now() + 2_000
    while (true) {
      const active = await admin!`select count(*)::int as count from pg_stat_activity where usename = 'fixture_app' and state = 'active' and query like '%inline_pool_cancel_fixture%'`
      if (Number(active[0]!["count"]) > 0) break
      if (Date.now() >= deadline) throw new Error("Fixture query did not start")
      await Bun.sleep(10)
    }
    query.cancel()
    expect(await result).toMatchObject({ code: "57014" })
    await clients!.validateStartup()
  }, 8_000)

  test("fresh client connections qualify again after the client pool closes", async () => {
    await clients!.close()
    clients = makeDatabaseClients(pooledUrl, { DATABASE_CONNECTION_MODE: "pgbouncer", DATABASE_DIRECT_URL: directUrl })
    await clients.validateStartup()
    expect((await clients.queryClient`select 1 as value`)[0]!["value"]).toBe(1)
  })

  test("readiness checks the actual pooled path and carries the database clock", async () => {
    const health = clients!.checkHealth()
    expect(typeof health.cancel).toBe("function")
    const rows = await health
    expect(Number(rows[0]!["database_time_millis"])).toBeGreaterThan(0)
    bouncer!.kill("SIGINT")
    await bouncer!.exited
    bouncer = undefined
    // PostgreSQL itself remains healthy; readiness must still reject.
    expect((await clients!.healthClient`select 1 as value`)[0]!["value"]).toBe(1)
    await expect(Promise.resolve(clients!.checkHealth())).rejects.toBeDefined()
  }, 10_000)
})
