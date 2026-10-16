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

test("both image publishing guards require manual same-repository branches and explicit publish-only off main", async () => {
  const workflow = Bun.YAML.parse(await Bun.file(resolve(import.meta.dir, "../../.github/workflows/server-test.yml")).text()) as {
    on: { workflow_call: { inputs: Record<string, { type: string; default: boolean }> } }
    jobs: Record<string, { steps: { name?: string; run?: string; if?: string; env?: Record<string, string> }[] }>
  }
  expect(workflow.on.workflow_call.inputs.publish_only).toMatchObject({ type: "boolean", default: false })
  for (const job of ["container", "container-arm"]) {
    const steps = workflow.jobs[job]!.steps
    const guard = steps.find((step) => step.name === "Require manual branch publication or main release")
    expect(guard?.run).toBeDefined()
    expect(guard?.if).toBe("${{ inputs.publish_image }}")
    expect(guard?.env?.PUBLISH_ONLY).toBe("${{ inputs.publish_only }}")
    // Reject before checkout/build or registry authentication can expose secrets.
    expect(steps.indexOf(guard!)).toBe(0)
    for (const event of ["workflow_dispatch", "push", "pull_request", "pull_request_target"]) {
      for (const repository of ["inline-chat/inline", "outsider/inline"]) {
        for (const [ref, refType] of [
          ["refs/heads/main", "branch"], ["refs/heads/codex/multi-node-ha", "branch"],
          ["refs/tags/main", "tag"], ["refs/pull/124/merge", "branch"],
        ] as const) {
          for (const publishOnly of ["true", "false", ""]) {
            const allowed = event === "workflow_dispatch" && repository === "inline-chat/inline"
              && refType === "branch" && ref.startsWith("refs/heads/")
              && (publishOnly === "true" || (publishOnly === "false" && ref === "refs/heads/main"))
            const result = Bun.spawnSync(["bash", "-e", "-c", guard!.run!], {
              env: { PATH: process.env.PATH, GITHUB_EVENT_NAME: event, GITHUB_REF: ref,
                GITHUB_REF_TYPE: refType, GITHUB_REPOSITORY: repository, PUBLISH_ONLY: publishOnly },
            })
            expect(result.exitCode === 0, `${job} ${event} ${repository} ${ref} publish-only=${publishOnly}`).toBe(allowed)
          }
        }
      }
    }
  }
})

type ReleaseJob = {
  if?: string
  needs?: string | string[]
  environment?: string
  uses?: string
  with?: Record<string, unknown>
  steps?: { name?: string; run?: string; if?: string; env?: Record<string, string> }[]
}
const releaseWorkflow = async () => Bun.YAML.parse(await Bun.file(
  resolve(import.meta.dir, "../../.github/workflows/server-deploy.yml"),
).text()) as {
  on: { workflow_dispatch: { inputs: { publish_only: { type: string; default: boolean }; bootstrap: { type: string; default: boolean } } } }
  jobs: Record<string, ReleaseJob>
}

test("ordinary releases synchronize and re-read Nuremberg before Fly without broad credentials", async () => {
  const workflow = await releaseWorkflow()
  expect(workflow.jobs.migrate?.needs).toContain("standby-preflight")
  expect(workflow.jobs.standby?.needs).toEqual(["qualify", "preflight", "migrate"])
  expect(workflow.jobs.deploy?.needs).toContain("standby")
  for (const id of ["standby-preflight", "standby"]) {
    expect(workflow.jobs[id]?.if).toBe("${{ github.ref == 'refs/heads/main' && !inputs.publish_only }}")
    expect(workflow.jobs[id]?.environment).toBe("production")
    expect(JSON.stringify(workflow.jobs[id])).not.toMatch(/COOLIFY_TOKEN|CLOUDFLARE_TOKEN|ROOT_SSH_KEY/)
  }
  const standbySteps = workflow.jobs.standby?.steps ?? []
  const alternate = standbySteps.findIndex((step) => step.name === "Keep a healthy unchanged Fly alternate while replacing Nuremberg")
  const sync = standbySteps.findIndex((step) => step.run?.includes("standby-release-client.py sync"))
  expect(alternate).toBe(sync - 1)
  expect(standbySteps[alternate]?.run).toContain('test "$current" = "$BASELINE"')
  expect(standbySteps[sync]?.if).toBe("${{ !inputs.bootstrap }}")
  const steps = workflow.jobs.deploy?.steps ?? []
  const check = steps.findIndex((step) => step.run?.includes("standby-release-client.py check"))
  const deploy = steps.findIndex((step) => step.run?.includes("flyctl deploy"))
  const flyReadback = steps.findIndex((step) => step.run?.includes("fly-release-wait.sh"))
  const complete = steps.findIndex((step) => step.run?.includes("standby-release-client.py complete"))
  expect(check).toBe(deploy - 1)
  expect(complete).toBeGreaterThan(flyReadback)
  for (const step of [steps[check], steps[complete]]) expect(step?.if).toBe("${{ !inputs.bootstrap }}")
})

test("publish-only keeps full CI and excludes every production job; normal and failed releases retain their gates", async () => {
  const workflow = await releaseWorkflow()
  expect(workflow.on.workflow_dispatch.inputs.publish_only).toMatchObject({ type: "boolean", default: false })
  expect(workflow.on.workflow_dispatch.inputs.bootstrap).toMatchObject({ type: "boolean", default: false })
  expect(workflow.jobs.qualify).toMatchObject({ needs: "validate", uses: "./.github/workflows/server-test.yml",
    with: { publish_image: true, publish_only: "${{ inputs.publish_only }}" } })
  expect(workflow.jobs.validate?.steps?.[0]?.env).toEqual({
    PUBLISH_ONLY: "${{ inputs.publish_only }}", BOOTSTRAP: "${{ inputs.bootstrap }}",
  })
  for (const id of ["preflight", "migrate", "deploy", "activate"]) {
    expect(workflow.jobs[id]?.if).toContain("github.ref == 'refs/heads/main'")
    expect(workflow.jobs[id]?.if).toContain("!inputs.publish_only")
  }
  // Interpret the workflow's deliberately simple boolean guards and dependency
  // success requirements, so changing either changes the jobs exercised here.
  const runnable = (id: string, publishOnly: boolean, failed?: string, bootstrap = false, ref = "refs/heads/main"): boolean => {
    const job = workflow.jobs[id]!
    if (job.if !== undefined) {
      const expression = job.if.match(/^\$\{\{\s*(.*?)\s*\}\}$/)?.[1]
      if (!expression) throw new Error("Unexpected release job condition")
      const clauses: Record<string, boolean> = {
        "github.ref == 'refs/heads/main'": ref === "refs/heads/main",
        "inputs.publish_only": publishOnly, "!inputs.publish_only": !publishOnly, "inputs.bootstrap": bootstrap,
      }
      if (!expression.split(" && ").every((clause) => {
        if (!(clause in clauses)) throw new Error(`Unexpected release condition: ${clause}`)
        return clauses[clause]
      })) return false
    }
    const needs = typeof job.needs === "string" ? [job.needs] : job.needs ?? []
    return needs.every((dependency) => dependency !== failed && runnable(dependency, publishOnly, failed, bootstrap, ref))
  }
  for (const [publishOnly, expected] of [
    [true, ["validate", "qualify", "prepared"]],
    [false, ["validate", "qualify", "preflight", "standby-preflight", "migrate", "standby", "deploy"]],
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
  expect(runnable("migrate", false, "standby-preflight")).toBe(false)
  expect(runnable("deploy", false, "standby")).toBe(false)
  expect(JSON.stringify(workflow.jobs.prepared)).not.toContain("secrets.")
  expect(workflow.jobs.prepared?.environment).toBeUndefined()
  expect(Object.keys(workflow.jobs).filter((job) => runnable(job, false, undefined, true)).sort())
    .toEqual(["activate", "deploy", "migrate", "preflight", "qualify", "standby", "standby-preflight", "validate"])
  expect(runnable("activate", false, "deploy", true)).toBe(false)
  for (const ref of ["refs/heads/main", "refs/heads/codex/multi-node-ha", "refs/tags/main"]) {
    for (const publishOnly of [true, false]) {
      for (const bootstrap of [true, false]) {
        for (const id of ["preflight", "migrate", "deploy", "activate"]) {
          // Test every production job's own fence even if upstream validation
          // were to accept a branch or conflicting inputs accidentally.
          expect(runnable(id, publishOnly, undefined, bootstrap, ref))
            .toBe(ref === "refs/heads/main" && !publishOnly && (id !== "activate" || bootstrap))
        }
      }
    }
  }
  expect(workflow.jobs.activate?.environment).toBe("production-cutover")
  const steps = workflow.jobs.activate?.steps ?? []
  const fence = steps.findIndex((step) => step.name === "Verify the predecessor is durably stopped")
  expect(fence).toBeGreaterThan(0)
  expect(steps[fence]?.env?.FLY_API_TOKEN).toBe("${{ secrets.LEGACY_FLY_READ_TOKEN }}")
  expect(steps[fence + 1]?.name).toBe("Activate the same qualified digest with workers")
  const validate = workflow.jobs.validate?.steps?.[0]?.run
  if (!validate) throw new Error("Missing dispatch guard")
  for (const event of ["workflow_dispatch", "push", "pull_request", "pull_request_target"]) {
    for (const repository of ["inline-chat/inline", "outsider/inline"]) {
      for (const [ref, refType] of [
        ["refs/heads/main", "branch"], ["refs/heads/codex/multi-node-ha", "branch"],
        ["refs/tags/main", "tag"], ["refs/pull/124/merge", "branch"],
      ] as const) {
        for (const publishOnly of ["false", "true", ""]) {
          for (const bootstrap of ["false", "true", ""]) {
            const permitted = event === "workflow_dispatch" && repository === "inline-chat/inline"
              && refType === "branch" && ref.startsWith("refs/heads/")
              && ((publishOnly === "true" && bootstrap === "false")
                || (publishOnly === "false" && ["true", "false"].includes(bootstrap) && ref === "refs/heads/main"))
            expect(Bun.spawnSync(["bash", "-e", "-c", validate], { env: {
              PATH: process.env.PATH, GITHUB_EVENT_NAME: event, GITHUB_REF: ref,
              GITHUB_REF_TYPE: refType, GITHUB_REPOSITORY: repository,
              PUBLISH_ONLY: publishOnly, BOOTSTRAP: bootstrap,
            } }).exitCode === 0, `${event} ${repository} ${ref} publish-only=${publishOnly} bootstrap=${bootstrap}`).toBe(permitted)
          }
        }
      }
    }
  }
})

const inspectInitial = (machines: unknown[], legacy = false) => Bun.spawnSync([
  "jq", "-ce", "--arg", "predecessor", "abc123", "-f",
  resolve(import.meta.dir, legacy ? "fly-release-machines-legacy.jq" : "fly-release-machines-bootstrap.jq"),
], { stdin: new TextEncoder().encode(JSON.stringify(machines)) })
const stopped = () => ({ ...machine(), version: "version1", state: "stopped", config: { ...machine().config, metadata: {}, services: [] } })
const bootstrapApi = () => ({ ...machine("api123"), version: "api-version",
  image_ref: { ...machine().image_ref, labels: { "org.opencontainers.image.revision": "a".repeat(40) } },
  config: { ...machine().config, env: { INLINE_PROCESS_ROLE: "api", INLINE_INGRESS_HOST: "api.inline.chat" },
    guest: { cpu_kind: "shared", cpus: 6, memory_mb: 1536 } },
})

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

test("bootstrap resume accepts exactly one healthy API-only Machine and rejects unsafe adoption", () => {
  const api = bootstrapApi()
  const result = inspectInitial([stopped(), api])
  expect(result.exitCode, result.stderr.toString()).toBe(0)
  expect(JSON.parse(result.stdout.toString())).toEqual({ ids: "abc123", machines: [{ id: "abc123", version: "version1" }],
    api: { id: "api123", version: "api-version", digest, revision: "a".repeat(40) } })
  for (const invalid of [
    { ...api, state: "created" }, { ...api, checks: [] }, { ...api, checks: [{ status: "critical" }] },
    { ...api, config: { ...api.config, env: { ...api.config.env, INLINE_PROCESS_ROLE: "all" } } },
    { ...api, config: { ...api.config, env: { ...api.config.env, INLINE_INGRESS_HOST: "other" } } },
    { ...api, config: { ...api.config, guest: { ...api.config.guest, cpus: 2 } } },
    { ...api, config: { ...api.config, metadata: {} } },
    { ...api, image_ref: { ...api.image_ref, digest: "latest" } },
    { ...api, image_ref: { ...api.image_ref, labels: {} } },
  ]) expect(inspectInitial([stopped(), invalid]).exitCode).not.toBe(0)
  expect(inspectInitial([api, { ...api, id: "other" }]).exitCode).not.toBe(0)
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

test("the actual first/resumed bootstrap shell preserves rehearsal Machines and refuses changed inventory", async () => {
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
  for (const machines of [[stopped()], [], [stopped(), bootstrapApi()]]) {
    await Bun.write(inventory, JSON.stringify(machines))
    const baseline = inspectInitial(machines).stdout.toString().trim()
    const result = execute(baseline)
    expect(result.exitCode, result.stderr.toString()).toBe(0)
    const args = (await Bun.file(calls).text()).trim().split("\n")
    expect(args).toContain(image)
    expect(args).toContain("--ha=false")
    expect(args).toContain("INLINE_PROCESS_ROLE=api")
    expect(args.join(" ")).not.toContain("INLINE_INGRESS_HOST")
    if (machines.length === 2) {
      expect(args).not.toContain("--exclude-machines")
      expect(args[args.indexOf("--only-machines") + 1]).toBe("api123")
      expect(args[args.indexOf("--strategy") + 1]).toBe("bluegreen")
    } else {
      expect(args).not.toContain("--only-machines")
      expect(args.includes("--exclude-machines")).toBe(machines.length > 0)
      expect(args[args.indexOf("--strategy") + 1]).toBe("immediate")
      if (machines.length) expect(args[args.indexOf("--exclude-machines") + 1]).toBe("abc123")
    }
    await Bun.write(calls, "not-called")
    await Bun.write(inventory, JSON.stringify([{ ...stopped(), version: "changed" }]))
    expect(execute(baseline).exitCode).not.toBe(0)
    expect(await Bun.file(calls).text()).toBe("not-called")
  }
})

test("readiness polling tolerates creation, requires the exact image, and has bounded reads and attempts", async () => {
  const directory = await mkdtemp(resolve(tmpdir(), "inline-release-wait-"))
  const initial = resolve(directory, "initial.json")
  const ready = resolve(directory, "ready.json")
  const count = resolve(directory, "count")
  const sleeps = resolve(directory, "sleeps")
  for (const [name, script] of Object.entries({
    flyctl: 'count=$(cat "$STUB_COUNT"); count=$((count + 1)); echo "$count" > "$STUB_COUNT"\nif [[ "$count" -ge "$STUB_READY_AFTER" ]]; then cat "$STUB_READY"; else cat "$STUB_INITIAL"; fi',
    timeout: 'test "$1" = --signal=KILL; test "$2" = 5s; shift 2; exec "$@"',
    sleep: 'test "$1" = 5; echo sleep >> "$STUB_SLEEPS"',
  })) {
    const path = resolve(directory, name)
    await Bun.write(path, `#!/bin/bash\nset -eu\n${script}\n`)
    await chmod(path, 0o700)
  }
  await Bun.write(initial, JSON.stringify([{ ...bootstrapApi(), state: "created", checks: [] }]))
  const execute = async (readyAfter: number, readyMachine = bootstrapApi()) => {
    await Bun.write(count, "0")
    await Bun.write(sleeps, "")
    await Bun.write(ready, JSON.stringify([readyMachine]))
    return Bun.spawnSync(["bash", "scripts/ci/fly-release-wait.sh", resolve(directory, "output.json"), "1", digest, "a".repeat(40)], {
      cwd: resolve(import.meta.dir, "../.."),
      env: { PATH: `${directory}:${process.env.PATH}`, STUB_COUNT: count, STUB_SLEEPS: sleeps,
        STUB_INITIAL: initial, STUB_READY: ready, STUB_READY_AFTER: String(readyAfter) },
    })
  }
  expect((await execute(3)).exitCode).toBe(0)
  expect((await Bun.file(count).text()).trim()).toBe("3")
  for (const [readyAfter, readyMachine] of [[31, bootstrapApi()], [1, { ...bootstrapApi(),
    image_ref: { ...bootstrapApi().image_ref, digest: "sha256:" + "2".repeat(64) } }]] as const) {
    const result = await execute(readyAfter, readyMachine)
    expect(result.exitCode).not.toBe(0)
    expect(result.stderr.toString()).toContain("Timed out waiting")
    expect((await Bun.file(count).text()).trim()).toBe("30")
    expect((await Bun.file(sleeps).text()).trim().split("\n")).toHaveLength(29)
  }
  const workflow = await releaseWorkflow()
  for (const job of ["deploy", "activate"]) {
    expect(workflow.jobs[job]?.steps?.some((step) => step.run?.includes("bash scripts/ci/fly-release-wait.sh"))).toBe(true)
  }
}, 15_000)

test("the publish-only summary records both qualified image digests and rejects mutable tags", async () => {
  const workflow = await releaseWorkflow()
  const script = workflow.jobs.prepared?.steps?.[0]?.run
  if (!script) throw new Error("Missing prepared image summary")
  const directory = await mkdtemp(resolve(tmpdir(), "inline-prepared-image-"))
  const summaryPath = resolve(directory, "summary.md")
  const image = `registry.fly.io/inline-api@${digest}`
  const standbyImage = `registry.fly.io/inline-api@sha256:${"2".repeat(64)}`
  const execute = (runtimeImage: string, standby = standbyImage) => Bun.spawnSync(["bash", "-e", "-c", script], {
    env: { PATH: process.env.PATH, GITHUB_SHA: "a".repeat(40), RUNTIME_IMAGE: runtimeImage, STANDBY_IMAGE: standby, GITHUB_STEP_SUMMARY: summaryPath },
  })
  expect(execute(image).exitCode).toBe(0)
  const output = await Bun.file(summaryPath).text()
  expect(output).toContain("a".repeat(40))
  expect(output).toContain(image)
  expect(output).toContain(standbyImage)
  expect(output).toContain("No Hetzner deployment was performed")
  expect(output).toContain("migrations, and deployment were skipped")
  expect(execute("registry.fly.io/inline-api:latest").exitCode).not.toBe(0)
  expect(execute(image, "registry.fly.io/inline-api:latest").exitCode).not.toBe(0)
  expect(execute(image, "").exitCode).not.toBe(0)
  expect(await Bun.file(summaryPath).text()).toBe(output)
})
