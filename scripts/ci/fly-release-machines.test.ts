import { expect, test } from "bun:test"
import { resolve } from "node:path"

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
