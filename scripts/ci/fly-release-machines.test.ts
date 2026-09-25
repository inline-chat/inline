import { expect, test } from "bun:test"
import { resolve } from "node:path"
import { chmod, mkdtemp } from "node:fs/promises"
import { tmpdir } from "node:os"

const digest = "sha256:" + "1".repeat(64)
const machine = (id = "abc123") => ({
  id, state: "started", host_status: "ok", cordoned: false,
  image_ref: { repository: "inline-api", tag: "existing", digest, labels: { "org.opencontainers.image.revision": "fixture-sha" } },
  config: {
    metadata: { fly_platform_version: "v2", fly_process_group: "app" },
    env: { SECRET: "fixture-not-for-summary" },
    services: [{ internal_port: 8000, checks: [{ path: "/readyz" }] }],
  },
  checks: [{ status: "passing" }],
})
const inspect = (machines: unknown[]) => Bun.spawnSync([
  "jq", "-ce", "-f", resolve(import.meta.dir, "fly-release-machines.jq"),
], { stdin: new TextEncoder().encode(JSON.stringify(machines)) })
const summary = (machines: unknown[]) => {
  const result = inspect(machines)
  expect(result.exitCode, result.stderr.toString()).toBe(0)
  return JSON.parse(result.stdout.toString())
}

test("one or two healthy public Machines retain their baseline and exclude service-free dark Machines", () => {
  const dark = { ...machine("dark123"), config: { ...machine().config, services: [] } }
  for (const publicMachines of [[machine()], [machine(), machine("abc234")]]) {
    const expected = { count: publicMachines.length, ids: publicMachines.map((m) => m.id).join(","), digest, revision: "fixture-sha" }
    expect(summary([...publicMachines, dark])).toEqual(expected)
    expect(summary([...publicMachines].reverse())).toEqual(expected)
  }
})

const rejected: [string, (m: ReturnType<typeof machine>) => unknown][] = [
  ["detached public Machine", (m) => ({ ...m, config: { ...m.config, metadata: { fly_process_group: "app" } } })],
  ["unexpected public group", (m) => ({ ...m, config: { ...m.config, metadata: { ...m.config.metadata, fly_process_group: "other" } } })],
  ["unexpected service port", (m) => ({ ...m, config: { ...m.config, services: [{ internal_port: 9000 }] } })],
  ["volume outside the Fly config", (m) => ({ ...m, config: { ...m.config, mounts: [{ volume: "fixture" }] } })],
  ["missing readiness check", (m) => ({ ...m, config: { ...m.config, services: [{ internal_port: 8000, checks: [] }] } })],
  ["missing check results", (m) => ({ ...m, checks: [] })],
  ["failed readiness check", (m) => ({ ...m, checks: [{ status: "critical" }] })],
  ["stopped Machine", (m) => ({ ...m, state: "stopped" })],
  ["cordoned Machine", (m) => ({ ...m, cordoned: true })],
  ["unobservable host", (m) => ({ id: m.id, state: "started", host_status: "unknown" })],
  ["mixed image digests", (m) => ({ ...m, image_ref: { ...m.image_ref, digest: "sha256:" + "2".repeat(64) } })],
  ["mixed Fly image tags", (m) => ({ ...m, image_ref: { ...m.image_ref, tag: "other" } })],
  ["missing digest", (m) => ({ ...m, image_ref: { ...m.image_ref, digest: "" } })],
  ["duplicate Machine ID", (m) => ({ ...m, id: "abc123" })],
]
test.each(rejected)("rejects %s even alongside a healthy managed Machine", (_name, mutate) => {
  const result = inspect([machine(), mutate(machine("abc234"))])
  expect(result.exitCode).not.toBe(0)
  expect(result.stdout.toString()).toBe("")
  expect(result.stderr.toString()).not.toContain("fixture-not-for-summary")
})

test("an empty fleet fails, and changed IDs, count or image cannot match the recorded baseline", () => {
  expect(inspect([]).exitCode).not.toBe(0)
  const before = summary([machine()])
  expect(summary([machine("abc234")])).not.toEqual(before)
  expect(summary([machine(), machine("abc234")])).not.toEqual(before)
  expect(summary([{ ...machine(), image_ref: { ...machine().image_ref, digest: "sha256:" + "2".repeat(64) } }])).not.toEqual(before)
})

test("the reusable workflow publishing guard only accepts manual main dispatch", async () => {
  const workflow = Bun.YAML.parse(await Bun.file(resolve(import.meta.dir, "../../.github/workflows/server-test.yml")).text()) as {
    jobs: { container: { steps: { name?: string; run?: string }[] } }
  }
  const guard = workflow.jobs.container.steps.find((step) => step.name === "Require manual main context when publishing")
  expect(guard?.run).toBeDefined()
  for (const [event, ref, allowed] of [
    ["workflow_dispatch", "refs/heads/main", true],
    ["push", "refs/heads/main", false],
    ["pull_request", "refs/heads/main", false],
    ["workflow_dispatch", "refs/heads/other", false],
  ] as const) {
    const result = Bun.spawnSync(["bash", "-e", "-c", guard!.run!], {
      env: { PATH: process.env.PATH, GITHUB_EVENT_NAME: event, GITHUB_REF: ref },
    })
    expect(result.exitCode === 0, `${event} ${ref}`).toBe(allowed)
  }
})

type ReleaseJob = {
  if?: string
  needs?: string | string[]
  environment?: string
  uses?: string
  with?: Record<string, unknown>
  steps?: { name?: string; run?: string; env?: Record<string, string> }[]
}
const releaseWorkflow = async () => Bun.YAML.parse(await Bun.file(
  resolve(import.meta.dir, "../../.github/workflows/server-deploy.yml"),
).text()) as {
  on: { workflow_dispatch: { inputs: { publish_only: { type: string; default: boolean }; bootstrap: { type: string; default: boolean } } } }
  jobs: Record<string, ReleaseJob>
}

test("publish-only keeps full CI and excludes every production job; normal and failed releases retain their gates", async () => {
  const workflow = await releaseWorkflow()
  expect(workflow.on.workflow_dispatch.inputs.publish_only).toMatchObject({ type: "boolean", default: false })
  expect(workflow.on.workflow_dispatch.inputs.bootstrap).toMatchObject({ type: "boolean", default: false })
  expect(workflow.jobs.qualify).toMatchObject({ needs: "validate", uses: "./.github/workflows/server-test.yml", with: { publish_image: true } })
  // Interpret the workflow's deliberately simple boolean guards and dependency
  // success requirements, so changing either changes the jobs exercised here.
  const runnable = (id: string, publishOnly: boolean, failed?: string, bootstrap = false): boolean => {
    const job = workflow.jobs[id]!
    if (job.if !== undefined) {
      const guard = job.if.match(/^\$\{\{\s*(!?)inputs\.(publish_only|bootstrap)\s*\}\}$/)
      if (!guard) throw new Error("Unexpected release job condition")
      const input = guard[2] === "bootstrap" ? bootstrap : publishOnly
      if (!(guard[1] ? !input : input)) return false
    }
    const needs = typeof job.needs === "string" ? [job.needs] : job.needs ?? []
    return needs.every((dependency) => dependency !== failed && runnable(dependency, publishOnly, failed, bootstrap))
  }
  for (const [publishOnly, expected] of [
    [true, ["validate", "qualify", "prepared"]],
    [false, ["validate", "qualify", "preflight", "migrate", "deploy"]],
  ] as const) {
    expect(Object.keys(workflow.jobs).filter((id) => runnable(id, publishOnly)).sort()).toEqual([...expected].sort())
    for (const [id, job] of Object.entries(workflow.jobs)) {
      if (job.environment?.startsWith("production") || JSON.stringify(job).includes("PRODUCTION_DATABASE_MIGRATION_URL")) {
        expect(runnable(id, true)).toBe(false)
      }
    }
    expect(runnable("prepared", publishOnly, "qualify")).toBe(false)
    expect(runnable("migrate", publishOnly, "qualify")).toBe(false)
    expect(runnable("deploy", publishOnly, "qualify")).toBe(false)
  }
  expect(runnable("qualify", true, "validate")).toBe(false)
  expect(runnable("migrate", false, "preflight")).toBe(false)
  expect(runnable("deploy", false, "migrate")).toBe(false)
  expect(JSON.stringify(workflow.jobs.prepared)).not.toContain("secrets.")
  expect(workflow.jobs.prepared?.environment).toBeUndefined()
  expect(Object.keys(workflow.jobs).filter((job) => runnable(job, false, undefined, true)).sort())
    .toEqual(["activate", "deploy", "migrate", "preflight", "qualify", "validate"])
  expect(runnable("activate", false, "deploy", true)).toBe(false)
  expect(workflow.jobs.activate?.environment).toBe("production-cutover")
  const steps = workflow.jobs.activate?.steps ?? []
  const fence = steps.findIndex((step) => step.name === "Verify the predecessor is durably stopped")
  expect(fence).toBeGreaterThan(0)
  expect(steps[fence]?.env?.FLY_API_TOKEN).toBe("${{ secrets.LEGACY_FLY_READ_TOKEN }}")
  expect(steps[fence + 1]?.name).toBe("Activate the same qualified digest with workers")
  const validate = workflow.jobs.validate?.steps?.[0]?.run
  if (!validate) throw new Error("Missing dispatch guard")
  for (const [publishOnly, bootstrap, permitted] of [[false, false, true], [true, false, true], [false, true, true], [true, true, false]]) {
    expect(Bun.spawnSync(["bash", "-e", "-c", validate], { env: {
      PATH: process.env.PATH, GITHUB_EVENT_NAME: "workflow_dispatch", GITHUB_REF: "refs/heads/main",
      PUBLISH_ONLY: String(publishOnly), BOOTSTRAP: String(bootstrap),
    } }).exitCode === 0).toBe(permitted)
  }
})

const inspectInitial = (machines: unknown[], legacy = false) => Bun.spawnSync([
  "jq", "-ce", "--arg", "predecessor", "abc123", "-f",
  resolve(import.meta.dir, legacy ? "fly-release-machines-legacy.jq" : "fly-release-machines-bootstrap.jq"),
], { stdin: new TextEncoder().encode(JSON.stringify(machines)) })
const stopped = () => ({ ...machine(), version: "version1", state: "stopped", config: { ...machine().config, metadata: {}, services: [] } })

test("bootstrap accepts empty or stopped service-free inventory and detects version changes", () => {
  expect(inspectInitial([]).exitCode).toBe(0)
  const before = inspectInitial([stopped()])
  expect(before.exitCode).toBe(0)
  expect(JSON.parse(before.stdout.toString())).toEqual({ ids: "abc123", machines: [{ id: "abc123", version: "version1" }] })
  const after = inspectInitial([{ ...stopped(), version: "version2" }])
  expect(after.exitCode).toBe(0)
  expect(after.stdout.toString()).not.toBe(before.stdout.toString())
  for (const invalid of [machine(), { ...stopped(), state: "started" }, { ...stopped(), config: machine().config },
    { ...stopped(), config: { ...stopped().config, metadata: machine().config.metadata } },
    { ...stopped(), host_status: "unknown" }, { ...stopped(), version: undefined }, { ...stopped(), config: null }]) {
    expect(inspectInitial([invalid]).exitCode).not.toBe(0)
  }
})

test("legacy fence requires the exact predecessor and refuses active or auto-startable old workers", () => {
  const predecessor = { ...stopped(), config: { ...machine().config, services: [{ internal_port: 8000, autostart: false }] } }
  expect(inspectInitial([predecessor], true).exitCode).toBe(0)
  for (const invalid of [[], [{ ...predecessor, id: "other" }], [{ ...predecessor, state: "started" }],
    [{ ...predecessor, host_status: "unknown" }], [{ ...predecessor, config: null }],
    [{ ...predecessor, config: { ...predecessor.config, services: [{ autostart: true }] } }],
    [{ ...predecessor, config: { ...predecessor.config, services: [{}] } }],
    [predecessor, { ...stopped(), id: "detached", state: "started" }]]) {
    expect(inspectInitial(invalid, true).exitCode).not.toBe(0)
  }
})

test("the actual bootstrap deploy shell excludes rehearsal Machines and refuses changed inventory", async () => {
  const workflow = await releaseWorkflow()
  const script = workflow.jobs.deploy?.steps?.find((step) => step.name === "Revalidate the recorded baseline and deploy the same digest")?.run
  if (!script) throw new Error("Missing deployment command")
  const directory = await mkdtemp(resolve(tmpdir(), "inline-bootstrap-shell-"))
  const inventory = resolve(directory, "inventory.json")
  const calls = resolve(directory, "calls.json")
  const executable = resolve(directory, "flyctl")
  await Bun.write(executable, '#!/bin/bash\nset -eu\nif [[ "$1 $2" = "machine list" ]]; then\n  cat "$STUB_INVENTORY"\nelse\n  printf "%s\\n" "$@" > "$STUB_CALLS"\nfi\n')
  await chmod(executable, 0o700)
  const image = `registry.fly.io/inline-api@${digest}`
  const execute = (baseline: string) => Bun.spawnSync(["bash", "-e", "-c", script], {
    cwd: resolve(import.meta.dir, "../.."),
    env: { PATH: `${directory}:${process.env.PATH}`, FLY_API_TOKEN: "synthetic", RUNTIME_IMAGE: image,
      BASELINE: baseline, BOOTSTRAP: "true", RUNNER_TEMP: directory, STUB_INVENTORY: inventory, STUB_CALLS: calls },
  })
  for (const machines of [[stopped()], []]) {
    await Bun.write(inventory, JSON.stringify(machines))
    const baseline = inspectInitial(machines).stdout.toString().trim()
    const result = execute(baseline)
    expect(result.exitCode, result.stderr.toString()).toBe(0)
    const args = (await Bun.file(calls).text()).trim().split("\n")
    expect(args).toContain(image)
    expect(args).toContain("--ha=false")
    expect(args).toContain("INLINE_PROCESS_ROLE=api")
    expect(args).not.toContain("--only-machines")
    expect(args.join(" ")).not.toContain("INLINE_INGRESS_HOST")
    expect(args.includes("--exclude-machines")).toBe(machines.length > 0)
    if (machines.length) expect(args[args.indexOf("--exclude-machines") + 1]).toBe("abc123")
    await Bun.write(calls, "not-called")
    await Bun.write(inventory, JSON.stringify([{ ...stopped(), version: "changed" }]))
    expect(execute(baseline).exitCode).not.toBe(0)
    expect(await Bun.file(calls).text()).toBe("not-called")
  }
})

test("the publish-only summary records the exact SHA and digest and rejects a mutable image tag", async () => {
  const workflow = await releaseWorkflow()
  const script = workflow.jobs.prepared?.steps?.[0]?.run
  if (!script) throw new Error("Missing prepared image summary")
  const directory = await mkdtemp(resolve(tmpdir(), "inline-prepared-image-"))
  const summaryPath = resolve(directory, "summary.md")
  const image = `registry.fly.io/inline-api@${digest}`
  const execute = (runtimeImage: string) => Bun.spawnSync(["bash", "-e", "-c", script], {
    env: { PATH: process.env.PATH, GITHUB_SHA: "a".repeat(40), RUNTIME_IMAGE: runtimeImage, GITHUB_STEP_SUMMARY: summaryPath },
  })
  expect(execute(image).exitCode).toBe(0)
  const output = await Bun.file(summaryPath).text()
  expect(output).toContain("a".repeat(40))
  expect(output).toContain(image)
  expect(output).toContain("migrations, and deployment were skipped")
  expect(execute("registry.fly.io/inline-api:latest").exitCode).not.toBe(0)
  expect(await Bun.file(summaryPath).text()).toBe(output)
})
