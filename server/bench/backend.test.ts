import { afterAll, beforeAll, test } from "bun:test"
import { writeFileSync, readFileSync, existsSync } from "node:fs"
import { createHash } from "node:crypto"
import { cpus } from "node:os"
import { resolve } from "node:path"
import { sql } from "drizzle-orm"
import { closeDb, db, initDb, validateDatabaseStartup } from "@in/server/db"
import { setupTestDatabase, teardownTestDatabase } from "@in/server/__tests__/database"
import { scenarios, scenarioVersion, selectScenarios } from "@in/server/__tests__/performance/catalog"
import { prepareScenario } from "@in/server/__tests__/performance/scenarios"
import { observeScenarioWork } from "@in/server/__tests__/performance/observe"
import { assertQueryBudget, measureOperation, type Sample } from "@in/server/__tests__/performance/measure"
import { createWireProxy } from "@in/server/__tests__/performance/wire"
import { summarize, type BenchmarkReport, type BenchmarkPreparation } from "@in/server/__tests__/performance/report"

const encoded = process.env["INLINE_BACKEND_BENCH_CONFIG"]
if (!encoded) throw new Error("Use bun run bench:backend; this worker needs the isolated benchmark launcher")
const config = JSON.parse(encoded) as { ids: string[]; samples: number; warmup: number; rtts: number[]; preparation: BenchmarkPreparation["mode"]; output: string }
if (config.preparation !== "access" && config.preparation !== "all-custom") throw new Error("Invalid benchmark preparation mode")
const previousPreparation = process.env["INLINE_DATABASE_PREPARED_QUERIES"]
const selected = selectScenarios(config.ids)
const background = observeScenarioWork()
let proxy: Awaited<ReturnType<typeof createWireProxy>> | undefined

beforeAll(async () => {
  await setupTestDatabase()
  const url = new URL(process.env["DATABASE_URL"]!)
  if (config.preparation === "all-custom") {
    // Only the lifecycle's freshly cloned database may receive this default.
    // No role change, provisioning database change, or session-only shortcut.
    const template = process.env["INLINE_TEST_DATABASE_TEMPLATE"]
    const name = url.pathname.slice(1)
    if (!template || !/^inline_test_template_[0-9]+_[0-9a-f]{32}$/.test(template) ||
        !new RegExp(`^test_db_${template.slice(-32)}_[0-9a-f]{12}$`).test(name) ||
        !["localhost", "127.0.0.1"].includes(url.hostname)) {
      throw new Error("Refusing to configure an unowned benchmark database")
    }
    const [current] = await db.execute<{ name: string }>(sql`select current_database() as name`)
    if (current?.name !== name) throw new Error("Benchmark database identity changed")
    await db.$client.unsafe(`ALTER DATABASE "${name}" SET plan_cache_mode = force_custom_plan`)
  }
  process.env["INLINE_DATABASE_PREPARED_QUERIES"] = config.preparation
  proxy = await createWireProxy({ host: url.hostname, port: Number(url.port || 5432) }, 0)
  url.hostname = "127.0.0.1"
  url.port = String(proxy.port)
  await closeDb()
  initDb(url.toString())
  await validateDatabaseStartup()
})
afterAll(async () => {
  try { await background.close() } finally {
    try { await teardownTestDatabase() } finally {
      try { await proxy?.close() } finally {
        if (previousPreparation === undefined) Reflect.deleteProperty(process.env, "INLINE_DATABASE_PREPARED_QUERIES")
        else process.env["INLINE_DATABASE_PREPARED_QUERIES"] = previousPreparation
      }
    }
  }
})

test("verified backend benchmark matrix", async () => {
  if (!proxy) throw new Error("Benchmark transport is not ready")
  const transport = proxy
  const [version] = await db.execute<{ server_version: string }>(sql`SHOW server_version`)
  const git = async (...args: string[]) => {
    const child = Bun.spawn(["git", ...args], { cwd: import.meta.dir, stdout: "pipe", stderr: "pipe" })
    const [code, out] = await Promise.all([child.exited, new Response(child.stdout).text(), new Response(child.stderr).text()])
    if (code) throw new Error("Cannot record benchmark Git revision")
    return out.trim()
  }
  const sourceDigest = async () => {
    const paths = (await git("ls-files", "-z", "--cached", "--others", "--exclude-standard", "--full-name", "--",
      "..", "../../packages", "../../bun.lock"))
      .split("\0").filter(Boolean).sort()
    const hash = createHash("sha256")
    for (const path of paths) {
      if (path.split("/").some((part) => part.startsWith(".env"))) continue
      const absolute = resolve(import.meta.dir, "../..", path)
      hash.update(path).update("\0").update(existsSync(absolute) ? readFileSync(absolute) : "<deleted>").update("\0")
    }
    return hash.digest("hex")
  }
  const digest = await sourceDigest()
  const dependencyVersion = (name: string): string => JSON.parse(readFileSync(new URL(`../node_modules/${name}/package.json`, import.meta.url), "utf8")).version
  const report: BenchmarkReport = {
    schemaVersion: 1, status: "passed", createdAt: new Date().toISOString(),
    revision: { commit: await git("rev-parse", "HEAD"), dirty: Boolean(await git("status", "--porcelain")), sourceDigest: digest },
    environment: {
      bun: Bun.version, postgres: version!.server_version, postgresJs: dependencyVersion("postgres"), drizzle: dependencyVersion("drizzle-orm"),
      platform: process.platform, arch: process.arch, cpu: cpus()[0]?.model ?? "unknown",
      poolMax: db.$client.options.max, clientPrepareDefault: db.$client.options.prepare,
      concurrency: 1, cache: "cold-application-warm-pool",
    },
    warmup: config.warmup, sampleCount: config.samples, results: [],
  }
  for (const rttMs of config.rtts) {
    for (const spec of selected) {
      const samples: Sample[] = []
      for (let iteration = 0; iteration < config.warmup + config.samples; iteration++) {
        transport.setDelay(0)
        await background.drain()
        const operation = await prepareScenario(spec)
        await background.drain()
        transport.setDelay(rttMs)
        let sample: Sample
        try { sample = await measureOperation(db.$client.options, operation.run, background.drain, transport) }
        finally { transport.setDelay(0) }
        await operation.verify()
        await background.drain()
        assertQueryBudget(spec.id, sample, spec.maxCommands)
        if (iteration >= config.warmup) samples.push(sample)
      }
      transport.setDelay(rttMs)
      const calibrationMs: number[] = []
      try {
        await db.execute(sql`select 1`)
        for (let i = 0; i < 10; i++) {
          const start = performance.now()
          await db.execute(sql`select 1`)
          calibrationMs.push(performance.now() - start)
        }
      } finally { transport.setDelay(0) }
      const result = { id: spec.id, version: scenarioVersion, size: spec.size, rttMs, maxCommands: spec.maxCommands, calibrationMs, samples }
      report.results.push(result)
      const summary = summarize(result)
      console.info(`${spec.id} RTT+${rttMs}ms: ${summary.commands.median} SQL, ${summary.exchanges.median} exchanges, ` +
        `${summary.operationMs.median.toFixed(2)}ms return / ${summary.settledMs.median.toFixed(2)}ms settled; SELECT 1 ${summary.calibrationMs.median.toFixed(2)}ms`)
    }
  }
  if (report.results.length !== selected.length * config.rtts.length || selected.some((entry) => !scenarios.includes(entry))) {
    throw new Error("Incomplete benchmark matrix")
  }
  const [settings] = await db.execute<{ mode: string; statements: number; custom: string; generic: string }>(sql`
    select current_setting('plan_cache_mode') as mode, count(*)::integer as statements,
      coalesce(sum(custom_plans), 0)::text as custom, coalesce(sum(generic_plans), 0)::text as generic
    from pg_prepared_statements
  `)
  if (!settings || !["auto", "force_custom_plan", "force_generic_plan"].includes(settings.mode)) {
    throw new Error("Cannot record benchmark planning policy")
  }
  if (config.preparation === "all-custom" && settings.mode !== "force_custom_plan") {
    throw new Error("Benchmark lost custom-plan qualification")
  }
  report.preparation = {
    mode: config.preparation, planCacheMode: settings.mode as BenchmarkPreparation["planCacheMode"],
    sampledBackendStatements: settings.statements,
    sampledBackendCustomPlans: Number(settings.custom), sampledBackendGenericPlans: Number(settings.generic),
  }
  console.info(`Preparation ${report.preparation.mode}; plan_cache_mode=${report.preparation.planCacheMode}; ` +
    `sampled backend: ${settings.statements} retained statements, ${settings.custom} custom / ${settings.generic} generic executions`)
  if (await sourceDigest() !== digest) throw new Error("Backend sources changed during the benchmark; rerun on a stable checkout")
  // The launcher promotes this only after Bun hooks and DB disposal also pass.
  writeFileSync(config.output, JSON.stringify({ ...report, status: "candidate" }, null, 2) + "\n", { flag: "wx" })
})
