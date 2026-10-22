import { describe, expect, it } from "bun:test"
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import path from "node:path"

const root = path.resolve(import.meta.dir, "../..")
type Step = { name?: string; run?: string; if?: string; uses?: string; with?: Record<string, unknown> }
const source = readFileSync(path.join(root, ".github/workflows/server-test.yml"), "utf8")
const workflow = Bun.YAML.parse(source) as {
  permissions: Record<string, string>
  on: { workflow_call: { secrets?: Record<string, unknown>; outputs: Record<string, { value: string }> } }
  jobs: Record<string, { if?: string; needs?: string[]; permissions?: Record<string, string>; steps: Step[] }>
}
const publish = workflow.jobs.publish!
const script = publish.steps.find((step) => step.name === "Publish qualified images without rebuilding and verify anonymous access")?.run
if (!script) throw new Error("Missing qualified image publication command")
const sha = "a".repeat(40)
const runtime = `ghcr.io/inline-chat/inline-server@sha256:${"1".repeat(64)}`
const standby = `ghcr.io/inline-chat/inline-server@sha256:${"2".repeat(64)}`

// This executable replaces Docker entirely. The test executes the workflow's
// real shell and jq parsing without starting a daemon or contacting a registry.
const docker = `#!/bin/bash
set -euo pipefail
printf '%s %s\n' "$DOCKER_CONFIG" "$*" >> "$STUB_CALLS"
case "$1" in
  login)
    test "$2" = ghcr.io
    test "$(cat)" = "$GHCR_TOKEN"
    printf authenticated > "$DOCKER_CONFIG/config.json"
    ;;
  load)
    test "$2" = --input
    test -f "$3"
    ;;
  image)
    test "$2" = inspect
    if [[ "$4" == *Architecture* ]]; then
      if [[ "$STUB_BAD_ARCH" = 1 ]]; then echo unsupported
      elif [[ "$5" == inline-server:ci-coolify ]]; then echo arm64
      else echo amd64; fi
    elif [[ "$4" == *org.opencontainers.image.revision* ]]; then
      if [[ "$STUB_BAD_SOURCE" = 1 ]]; then echo wrong-source; else echo "$GITHUB_SHA"; fi
    elif [[ "$4" == *RepoDigests* ]]; then
      if [[ "$STUB_BAD_DIGEST" = 1 ]]; then echo '["ghcr.io/inline-chat/inline-server@sha256:bad"]'
      elif [[ "$5" == *coolify-arm64* ]]; then printf '["%s"]\n' "$STUB_STANDBY"
      else printf '["%s"]\n' "$STUB_RUNTIME"; fi
    else exit 91; fi
    ;;
  tag|push) ;;
  manifest)
    test "$2" = inspect
    test ! -f "$DOCKER_CONFIG/config.json"
    if [[ "$STUB_PRIVATE" = 1 || ( "$STUB_PRIVATE" = arm64 && "$3" = "$STUB_STANDBY" ) ]]; then exit 1; fi
    printf '{"schemaVersion":2}'
    ;;
  *) exit 92 ;;
esac
`

function execute(overrides: Record<string, string | undefined> = {}) {
  const directory = mkdtempSync(path.join(tmpdir(), "inline-ghcr-publish-"))
  const output = path.join(directory, "output")
  const calls = path.join(directory, "calls")
  const images = path.join(directory, "server-images")
  try {
    mkdirSync(images)
    writeFileSync(path.join(images, "runtime-amd64.tar.gz"), "qualified-runtime")
    writeFileSync(path.join(images, "coolify-arm64.tar.gz"), "qualified-arm64")
    const executable = path.join(directory, "docker")
    writeFileSync(executable, docker)
    chmodSync(executable, 0o700)
    writeFileSync(output, "")
    writeFileSync(calls, "")
    const result = Bun.spawnSync(["bash", "-e", "-c", script!], {
      cwd: root,
      env: {
        PATH: `${directory}:${process.env.PATH}`, RUNNER_TEMP: directory, GITHUB_OUTPUT: output,
        GITHUB_SHA: sha, GITHUB_ACTOR: "release-fixture", GITHUB_RUN_ID: "42", GITHUB_RUN_ATTEMPT: "2",
        GHCR_TOKEN: "synthetic-token", STUB_CALLS: calls, STUB_RUNTIME: runtime, STUB_STANDBY: standby,
        STUB_BAD_ARCH: "0", STUB_BAD_SOURCE: "0", STUB_BAD_DIGEST: "0", STUB_PRIVATE: "0", ...overrides,
      },
    })
    return {
      code: result.exitCode, stderr: result.stderr.toString(), stdout: result.stdout.toString(),
      output: readFileSync(output, "utf8"), calls: readFileSync(calls, "utf8"),
    }
  } finally {
    rmSync(directory, { recursive: true, force: true })
  }
}

describe("qualified server image publication", () => {
  it("publishes the qualified archives unchanged and emits public immutable digests", () => {
    const result = execute()
    expect(result.code, result.stderr).toBe(0)
    expect(result.output).toBe(`runtime_image=${runtime}\nstandby_image=${standby}\n`)
    expect(result.calls).toContain(`push ghcr.io/inline-chat/inline-server:runtime-amd64-${sha}-42-2`)
    expect(result.calls).toContain(`push ghcr.io/inline-chat/inline-server:coolify-arm64-${sha}-42-2`)
    expect(result.calls).toContain(`manifest inspect ${runtime}`)
    expect(result.calls).toContain(`manifest inspect ${standby}`)
    expect(result.calls).not.toContain(" build ")
    expect(result.calls).not.toContain(" run ")
    expect(result.calls).not.toContain("synthetic-token")
    expect(result.stdout + result.stderr).not.toContain("synthetic-token")
  })

  it("rejects an archive with the wrong source or architecture before any push", () => {
    for (const overrides of [{ STUB_BAD_SOURCE: "1" }, { STUB_BAD_ARCH: "1" }]) {
      const result = execute(overrides)
      expect(result.code).not.toBe(0)
      expect(result.output).toBe("")
      expect(result.calls).not.toContain(" push ")
    }
  })

  it("withholds release outputs if GHCR is private or the returned digest is invalid", () => {
    for (const overrides of [{ STUB_PRIVATE: "1" }, { STUB_PRIVATE: "arm64" }, { STUB_BAD_DIGEST: "1" }]) {
      const result = execute(overrides)
      expect(result.code).not.toBe(0)
      expect(result.output).toBe("")
    }
  })

  it("rejects malformed release identity before registry login", () => {
    for (const overrides of [{ GITHUB_SHA: "main" }, { GITHUB_RUN_ID: "x" }, { GITHUB_RUN_ATTEMPT: "x" }]) {
      const result = execute(overrides)
      expect(result.code, JSON.stringify(overrides)).not.toBe(0)
      expect(result.calls).toBe("")
    }
  })

  it("keeps write permission in the manual publisher after all server jobs pass", () => {
    expect(workflow.permissions).toEqual({ contents: "read" })
    expect(publish.if).toBe("${{ inputs.publish_image }}")
    expect(publish.needs).toEqual(["container", "container-arm", "test"])
    expect(publish.permissions).toEqual({ contents: "read", packages: "write" })
    for (const name of ["container", "container-arm", "test", "required"]) {
      expect(workflow.jobs[name]!.permissions?.packages).not.toBe("write")
    }
    expect(workflow.on.workflow_call.secrets).toBeUndefined()
    expect(workflow.on.workflow_call.outputs.runtime_image!.value).toBe("${{ jobs.publish.outputs.runtime_image }}")
    expect(workflow.on.workflow_call.outputs.standby_image!.value).toBe("${{ jobs.publish.outputs.standby_image }}")
    const guard = publish.steps[0]!
    expect(guard.name).toBe("Require manual branch publication or main release")
    for (const event of ["push", "pull_request", "pull_request_target"]) {
      const result = Bun.spawnSync(["bash", "-e", "-c", guard.run!], { env: {
        PATH: process.env.PATH, GITHUB_EVENT_NAME: event, GITHUB_REPOSITORY: "inline-chat/inline",
        GITHUB_REF_TYPE: "branch", GITHUB_REF: "refs/heads/main", PUBLISH_ONLY: "false",
      } })
      expect(result.exitCode).not.toBe(0)
    }
    expect(source).not.toContain("FLY_API_TOKEN")
    expect(source).not.toContain("registry.fly.io")
  })
})
