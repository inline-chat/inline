import { expect, test } from "bun:test"
import postgres from "postgres"
import { drizzle } from "drizzle-orm/postgres-js"
import { sql } from "drizzle-orm"
import { accessQueryComment } from "./databaseDiagnostics"
import { setupTestLifecycle } from "../__tests__/database"
import { createWireProxy } from "../__tests__/performance/wire"
import { MAX_BROAD_PREPARED_QUERY_SHAPES, MAX_PREPARED_QUERY_SHAPES, prepareQueries, type PreparedQueryPolicy } from "./preparedQueries"

setupTestLifecycle()

async function withClient(run: (client: postgres.Sql, proxy: Awaited<ReturnType<typeof createWireProxy>>) => Promise<void>, mode: PreparedQueryPolicy["mode"] = "all-custom") {
  const url = new URL(process.env["DATABASE_URL"]!)
  const proxy = await createWireProxy({ host: url.hostname, port: Number(url.port || 5432) }, 0)
  url.hostname = "127.0.0.1"
  url.port = String(proxy.port)
  const client = postgres(url.toString(), { max: 1, ssl: false, connection: { plan_cache_mode: "force_custom_plan" } })
  prepareQueries(client, { mode })
  prepareQueries(client) // Installing twice must not stack wrappers or reset the shape budget.
  try {
    await client`select 1`
    await run(client, proxy)
  } finally {
    await client.end()
    await proxy.close()
  }
}

test("Drizzle reuses plans with new values in the pool, transactions and savepoints", async () => {
  await withClient(async (client, proxy) => {
    const db = drizzle(client)
    const read = async (value: number) => {
      const rows = await db.execute(sql`select ${value}::int as value`)
      expect(rows[0]?.["value"]).toBe(value)
    }
    await read(0)
    await read(1)
    proxy.reset()
    await read(2)
    expect(proxy.snapshot().frames["H"] ?? 0).toBe(0)
    expect(proxy.snapshot().frames["P"] ?? 0).toBe(0)
    expect(proxy.snapshot().exchangeBoundaries).toBe(1)

    const nestedRead = (value: number) => db.transaction(async (tx) => {
      const rows = await tx.execute(sql`select ${value}::int + 10 as value`)
      expect(rows[0]?.["value"]).toBe(value + 10)
      await tx.transaction(async (nested) => {
        const inner = await nested.execute(sql`select ${value}::int + 20 as value`)
        expect(inner[0]?.["value"]).toBe(value + 20)
      })
    }, { isolationLevel: "repeatable read", accessMode: "read only" })
    await nestedRead(2)
    await nestedRead(3)
    proxy.reset()
    await nestedRead(4)
    expect(proxy.snapshot().frames["H"] ?? 0).toBe(0)
    expect(proxy.snapshot().frames["P"] ?? 0).toBe(0)

    const reserved = await client.reserve()
    try {
      await reserved.unsafe("select $1::int + 30 as value", [4])
      await reserved.unsafe("select $1::int + 30 as value", [5])
      proxy.reset()
      const rows = await reserved.unsafe("select $1::int + 30 as value", [6])
      expect(rows[0]?.["value"]).toBe(36)
      expect(proxy.snapshot().exchangeBoundaries).toBe(1)
    } finally { reserved.release() }
  })
})

test("prepared writes preserve savepoint and outer transaction rollback", async () => {
  await withClient(async (client) => {
    const db = drizzle(client)
    await db.execute(sql`create temporary table prepared_write_test (id integer primary key)`)
    await db.transaction(async (tx) => {
      await tx.execute(sql`insert into prepared_write_test values (${1})`)
      await expect(tx.transaction(async (nested) => {
        await nested.execute(sql`insert into prepared_write_test values (${2})`)
        throw new Error("rollback inner")
      })).rejects.toThrow("rollback inner")
      await tx.execute(sql`insert into prepared_write_test values (${3})`)
    })
    await expect(db.transaction(async (tx) => {
      await tx.execute(sql`insert into prepared_write_test values (${4})`)
      throw new Error("rollback outer")
    })).rejects.toThrow("rollback outer")
    const rows = await db.execute(sql`select id from prepared_write_test order by id`)
    expect(rows.map((row) => row["id"])).toEqual([1, 3])
  })
})

test("explicit opt-out and shape-budget overflow still execute correctly without retaining new plans", async () => {
  await withClient(async (client, proxy) => {
    const query = "select $1::int as value"
    await client.unsafe(query, [0])
    await client.unsafe(query, [1])
    proxy.reset()
    expect((await client.unsafe(query, [2], { prepare: false }))[0]?.["value"]).toBe(2)
    expect(proxy.snapshot().frames["H"]).toBe(1)
    for (let i = 1; i < MAX_BROAD_PREPARED_QUERY_SHAPES; i++) {
      await client.unsafe(`select $1::int + ${i} as value`, [0])
      await client.unsafe(`select $1::int + ${i} as value`, [1])
    }
    const overflow = `select $1::int + ${MAX_PREPARED_QUERY_SHAPES} as value`
    await client.unsafe(overflow, [1])
    proxy.reset()
    expect((await client.unsafe(overflow, [2]))[0]?.["value"]).toBe(MAX_PREPARED_QUERY_SHAPES + 2)
    expect(proxy.snapshot().frames["H"]).toBe(1)
    const access = `select $1::int as access_value ${accessQueryComment("sync.replay")}`
    await client.unsafe(access, [1])
    proxy.reset()
    expect((await client.unsafe(access, [2]))[0]?.["access_value"]).toBe(2)
    expect(proxy.snapshot().exchangeBoundaries).toBe(1)
    proxy.reset()
    expect((await client.unsafe(query, [3]))[0]?.["value"]).toBe(3)
    expect(proxy.snapshot().exchangeBoundaries).toBe(1)
  })
})


test("nullable scalar type changes and custom typed parameters keep their original values", async () => {
  await withClient(async (client, proxy) => {
    for (const value of [true, null, false, null]) {
      expect((await client.unsafe("select $1::boolean as value", [value]))[0]?.["value"]).toBe(value)
    }
    const typed = () => client.unsafe("select $1::int as typed", [client.typed(7, 23)])
    await typed()
    proxy.reset()
    expect((await typed())[0]?.["typed"]).toBe(7)
    expect(proxy.snapshot().frames["H"]).toBe(1)
  })
})

test("ordinary array bindings reuse plans with changed lengths and values", async () => {
  await withClient(async (client, proxy) => {
    // JSON readback avoids the driver's numeric-array NULL parser so this
    // checks the bound database values, including NULL and an empty array.
    const query = "select to_json($1::integer[]) as ids"
    await client.unsafe(query, [[1]])
    await client.unsafe(query, [[1, 2]])
    for (const ids of [[3], [4, 5, 6], [], [null, 7]]) {
      proxy.reset()
      expect((await client.unsafe(query, [ids]))[0]?.["ids"]).toEqual(ids)
      expect(proxy.snapshot().frames["P"] ?? 0).toBe(0)
      expect(proxy.snapshot().frames["H"] ?? 0).toBe(0)
      expect(proxy.snapshot().exchangeBoundaries).toBe(1)
    }
  })
})


test("default policy leaves unrelated partial-index predicates unnamed after repeated reads", async () => {
  await withClient(async (client, proxy) => {
    await client`set plan_cache_mode = auto`
    await client`create temporary table prepared_partial_test (id int, stopped boolean)`
    await client`insert into prepared_partial_test select id, id > 10 from generate_series(1, 10000) id`
    await client`create index prepared_partial_due on prepared_partial_test (id) where stopped = false`
    await client`analyze prepared_partial_test`
    const query = "select id from prepared_partial_test where stopped = $1 order by id"
    for (let run = 0; run < 12; run++) expect(await client.unsafe(query, [false])).toHaveLength(10)
    proxy.reset()
    expect(await client.unsafe(query, [false])).toHaveLength(10)
    expect(proxy.snapshot().frames["H"]).toBe(1)
    const retained = await client`select name from pg_prepared_statements where statement = ${query}`
    expect(retained).toHaveLength(0)
    const plan = await client.unsafe(`explain (format json) ${query}`, [false])
    expect(JSON.stringify(plan)).toContain("prepared_partial_due")
    const access = `select $1::int as value ${accessQueryComment("sync.replay")}`
    await client.unsafe(access, [1])
    proxy.reset()
    expect((await client.unsafe(access, [2]))[0]?.["value"]).toBe(2)
    expect(proxy.snapshot().exchangeBoundaries).toBe(1)
  }, "access")
})

test("broad custom plans retain partial indexes and skip Describe after more than five executions", async () => {
  await withClient(async (client, proxy) => {
    await client`create temporary table prepared_custom_test (id int, stopped boolean)`
    await client`insert into prepared_custom_test select id, id > 10 from generate_series(1, 10000) id`
    await client`create index prepared_custom_due on prepared_custom_test (id) where stopped = false`
    await client`analyze prepared_custom_test`
    const query = "select id from prepared_custom_test where stopped = $1 order by id"
    for (let run = 0; run < 12; run++) expect(await client.unsafe(query, [false])).toHaveLength(10)
    proxy.reset()
    expect(await client.unsafe(query, [false])).toHaveLength(10)
    expect(proxy.snapshot().exchangeBoundaries).toBe(1)
    const plans = await client`select name, generic_plans, custom_plans from pg_prepared_statements where statement = ${query}`
    expect(plans).toHaveLength(1)
    expect(Number(plans[0]?.["generic_plans"])).toBe(0)
    expect(Number(plans[0]?.["custom_plans"])).toBeGreaterThan(5)
    const name = String(plans[0]?.["name"]).replaceAll('"', '""')
    const plan = await client.unsafe(`explain (format json) execute "${name}"(false)`)
    expect(JSON.stringify(plan)).toContain("prepared_custom_due")
  })
})

test("one-off shapes do not exhaust broad admission and access keeps reserved capacity", async () => {
  await withClient(async (client, proxy) => {
    for (let i = 0; i < MAX_PREPARED_QUERY_SHAPES + 20; i++) {
      await client.unsafe(`select $1::int + ${i} as one_off`, [1])
    }
    const hot = "select $1::int as hot"
    await client.unsafe(hot, [1])
    await client.unsafe(hot, [2])
    proxy.reset()
    expect((await client.unsafe(hot, [3]))[0]?.["hot"]).toBe(3)
    expect(proxy.snapshot().exchangeBoundaries).toBe(1)
    const plans = await client`select count(*)::int as count from pg_prepared_statements where statement like '%as one_off'`
    expect(plans[0]?.["count"]).toBe(0)
  })
})
