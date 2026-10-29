import { afterAll, beforeAll, describe, expect, it } from "bun:test"
import { execFileSync } from "node:child_process"
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import path from "node:path"
import { PACKAGE_CONFIGS, canonicalSemver, parseReleaseTag } from "./release-tag.mjs"
import { CLI_UPDATE_JOBS, qualifyRelease, REQUIRED_JOBS } from "./assert-release-commit.mjs"
import { checkInternalDependencies, validateSourceManifest } from "./npm-release-preflight.mjs"

describe("immutable release tag identity", () => {
  it("takes independent package and CLI versions from tags", () => {
    for (const config of Object.values(PACKAGE_CONFIGS)) {
      expect(parseReleaseTag(`${config.key}-v1.2.3-alpha.4`, "npm")).toMatchObject({
        packageKey: config.key, name: config.name, directory: config.directory, version: "1.2.3-alpha.4", channel: "alpha",
      })
    }
    expect(parseReleaseTag("cli-v2.3.4-rc.1", "cli")).toMatchObject({ version: "2.3.4-rc.1", channel: "rc" })
    expect(parseReleaseTag("protocol-v0.0.13").channel).toBe("latest")
  })

  it("rejects ambiguous versions, unsupported surfaces and tag injection", () => {
    for (const value of ["v1.2.3", "01.2.3", "1.2", "1.2.3-alpha.01", "1.2.3+different-bytes", "1.2.3\n", "1.2.3/evil"]) {
      expect(() => canonicalSemver(value)).toThrow()
    }
    for (const tag of ["private-v1.2.3", "protocol-v1.2.3-rc.1", "refs/tags/protocol-v1.2.3", "protocol-v1.2.3\nother=value"]) {
      expect(() => parseReleaseTag(tag, "npm")).toThrow()
    }
    expect(() => parseReleaseTag("cli-v1.2.3", "npm")).toThrow("Expected a npm")
  })
})

describe("release main qualification through real Git", () => {
  let directory: string, checkout: string, candidate: string, updaterCandidate: string, newer: string, offMain: string
  const env = { ...process.env, GIT_CONFIG_NOSYSTEM: "1", GIT_CONFIG_GLOBAL: "/dev/null", GIT_TERMINAL_PROMPT: "0" }
  const git = (cwd: string, ...args: string[]) => execFileSync("git", args, { cwd, env, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] }).trim()
  beforeAll(() => {
    directory = mkdtempSync(path.join(tmpdir(), "inline-tag-gates-"))
    const source = path.join(directory, "source"), origin = path.join(directory, "origin.git")
    checkout = path.join(directory, "checkout")
    git(directory, "init", "--bare", "--initial-branch=main", origin)
    git(directory, "init", "--initial-branch=main", source)
    git(source, "config", "user.name", "Release fixture")
    git(source, "config", "user.email", "release-fixture@example.invalid")
    git(source, "config", "core.hooksPath", "/dev/null")
    git(source, "remote", "add", "origin", origin)
    const commit = (text: string) => {
      writeFileSync(path.join(source, "source.txt"), text)
      git(source, "add", "source.txt"); git(source, "commit", "-m", text)
      return git(source, "rev-parse", "HEAD")
    }
    candidate = commit("selected source")
    git(source, "tag", "-a", "protocol-v1.2.3-alpha.1", "-m", "selected", candidate)
    git(source, "tag", "cli-v2.3.4", candidate)
    mkdirSync(path.join(source, "cli"))
    writeFileSync(path.join(source, "cli/update-compatibility.json"), "{}")
    git(source, "add", "cli/update-compatibility.json")
    updaterCandidate = commit("CLI updater contract")
    git(source, "tag", "cli-v2.3.5", updaterCandidate)
    newer = commit("trusted main advanced")
    git(source, "push", "origin", "main", "--tags")
    git(source, "checkout", "-b", "off-main", candidate)
    offMain = commit("unqualified source")
    git(source, "tag", "protocol-v9.9.9", offMain)
    git(source, "push", "origin", "off-main", "--tags")
    git(directory, "clone", origin, checkout)
  }, 15_000)
  afterAll(() => { if (directory) rmSync(directory, { recursive: true, force: true }) })
  const run = (id = 10, extra = {}) => ({ id, head_sha: candidate, head_branch: "main", event: "push",
    head_repository: { full_name: "inline-chat/inline" }, status: "completed", conclusion: "success", ...extra })
  const api = (surface: "npm" | "cli", runs = [run()], missing = "") => (resource: string) => resource.includes("/runs?")
    ? { workflow_runs: runs }
    : { jobs: REQUIRED_JOBS[surface].map((name: string) => ({ name, status: "completed", conclusion: name === missing ? "failure" : "success" })) }
  const gate = (extra = {}) => qualifyRelease({ tag: "protocol-v1.2.3-alpha.1", commit: candidate, surface: "npm",
    repository: "inline-chat/inline", runGit: (...args: string[]) => git(checkout, ...args), api: api("npm"), ...extra })

  it("peels an annotated tag and accepts the frozen source after main advances without executing it", () => {
    expect(gate()).toMatchObject({ sha: candidate, version: "1.2.3-alpha.1", "package-key": "protocol" })
    expect(git(checkout, "rev-parse", "HEAD")).toBe(newer)
    expect(readFileSync(path.join(checkout, "source.txt"), "utf8")).toBe("trusted main advanced")
  })

  it("rejects off-main or mismatched tags and malformed commits before CI", () => {
    for (const extra of [{ tag: "protocol-v9.9.9", commit: offMain }, { commit: newer }, { commit: "main" }, { repository: "attacker/inline" }]) {
      let requested = false
      expect(() => gate({ ...extra, api: () => { requested = true; throw new Error("must not request CI") } })).toThrow()
      expect(requested).toBe(false)
    }
  })

  it("accepts CLI diagnostic commits but never untagged publication", () => {
    expect(gate({ surface: "cli", tag: "", allowUntagged: true, api: api("cli") })).toMatchObject({ sha: candidate, tag: "", version: "" })
    expect(() => gate({ tag: "" })).toThrow("existing release tag")
  })

  it("does not count PR, fork, pending or older green runs as the selected main result", () => {
    for (const runs of [[run(10, { event: "pull_request" })], [run(10, { head_repository: { full_name: "attacker/inline" } })], [run(10, { status: "in_progress" })]]) {
      expect(() => gate({ api: api("npm", runs) })).toThrow("not complete")
    }
    expect(() => gate({ api: api("npm", [run(9), run(10, { conclusion: "failure" })], "Shared TypeScript packages") })).toThrow("has not passed")
  })

  it("uses surface jobs instead of unrelated Apple/server/global failures", () => {
    expect(gate({ surface: "cli", tag: "cli-v2.3.4", api: api("cli", [run(10, { conclusion: "failure" })]) })).toMatchObject({ sha: candidate })
    expect(() => gate({ api: api("npm", [run()], "Packed consumer (Node 20)") })).toThrow("Packed consumer")
  })

  const updaterRun = (extra = {}, id = 20) => run(id, { head_sha: updaterCandidate, ...extra })
  const updaterApi = (runs = [updaterRun()], jobs = CLI_UPDATE_JOBS.map((name) => ({ name, status: "completed", conclusion: "success" }))) => (resource: string) => {
    if (resource.includes("workflows/cli-update-qualification.yml/")) return { workflow_runs: runs }
    if (resource.includes("actions/runs/20/") || resource.includes("actions/runs/21/")) return { jobs }
    return api("cli", [run(10, { head_sha: updaterCandidate })])(resource)
  }
  const updaterGate = (extra = {}) => gate({ tag: "cli-v2.3.5", commit: updaterCandidate, surface: "cli", api: updaterApi(), ...extra })

  it("requires updater qualification on both operating systems for the exact new CLI source", () => {
    expect(updaterGate()).toMatchObject({ sha: updaterCandidate, outcome: "qualified" })
    for (const name of CLI_UPDATE_JOBS) {
      const jobs = CLI_UPDATE_JOBS.map((job) => ({ name: job, status: "completed", conclusion: job === name ? "failure" : "success" }))
      expect(() => updaterGate({ api: updaterApi([updaterRun()], jobs) })).toThrow(name)
      expect(() => updaterGate({ api: updaterApi([updaterRun()], jobs.filter((job) => job.name !== name)) })).toThrow(name)
    }
  })

  it("defers CLI publication until its latest trusted main updater run completes", () => {
    for (const runs of [[], [updaterRun({ head_sha: candidate })], [updaterRun({ event: "pull_request" })],
      [updaterRun({ head_branch: "other" })], [updaterRun({ head_repository: { full_name: "attacker/inline" } })],
      [updaterRun(), updaterRun({ status: "in_progress" }, 21)]]) {
      try {
        updaterGate({ api: updaterApi(runs) })
        throw new Error("Accepted an unqualified updater")
      } catch (error: any) {
        expect(error.outcome).toBe("deferred")
        expect(error.message).toContain("CLI update qualification")
      }
    }
  })

  it("preserves older CLI retries but fails closed if candidate metadata cannot be read", () => {
    const requests: string[] = []
    expect(gate({ tag: "cli-v2.3.4", surface: "cli", api: (resource: string) => {
      requests.push(resource); return api("cli")(resource)
    } })).toMatchObject({ sha: candidate })
    expect(requests.every((resource) => !resource.includes("cli-update-qualification"))).toBe(true)
    expect(() => updaterGate({ runGit: (...args: string[]) => {
      if (args[0] === "ls-tree") throw new Error("candidate metadata unavailable")
      return git(checkout, ...args)
    } })).toThrow("candidate metadata unavailable")
  })
})

describe("npm declared dependency preflight", () => {
  const release = parseReleaseTag("bot-client-v1.2.3-alpha.1", "npm")
  const manifest = { name: release.name, version: release.version, repository: { url: "git+https://github.com/inline-chat/inline.git", directory: release.directory }, publishConfig: { access: "public" }, dependencies: { "@inline-chat/bot-api-types": "0.1.3-alpha.0" } }
  it("requires a committed release version while preserving declared requirements", () => {
    const before = JSON.stringify(manifest)
    validateSourceManifest(manifest, release)
    const requests: string[] = []
    checkInternalDependencies(manifest, (name: string, version: string) => { requests.push(`${name}@${version}`); return version })
    expect(requests).toEqual(["@inline-chat/bot-api-types@0.1.3-alpha.0"])
    expect(JSON.stringify(manifest)).toBe(before)
    expect(() => validateSourceManifest({ ...manifest, version: "0.1.2-alpha.0" }, release)).toThrow("Commit the package version")
  })
  it("blocks missing dependencies and workspace/private aliases without rewriting them", () => {
    expect(() => checkInternalDependencies(manifest, () => null)).toThrow("Publish internal dependency")
    for (const spec of ["workspace:*", "file:../types", "npm:@inline-chat/bot-api-types@0.1.3-alpha.0"]) {
      expect(() => checkInternalDependencies({ dependencies: { "@inline-chat/bot-api-types": spec } })).toThrow("registry requirement")
    }
    expect(() => checkInternalDependencies({ dependencies: { "@inline-chat/oauth-core": "1.2.3" } })).toThrow("registry requirement")
  })
  it("checks every runtime/optional/peer requirement and preserves registry failures", () => {
    expect(() => checkInternalDependencies({ ...manifest, peerDependencies: { "@inline-chat/bot-api-types": "*" } }, (_: string, spec: string) => spec === "*" ? "1.0.0" : null)).toThrow("0.1.3-alpha.0")
    expect(() => checkInternalDependencies(manifest, () => { throw new Error("registry E401") })).toThrow("E401")
    expect(() => validateSourceManifest({ ...manifest, private: true }, release)).toThrow("identity")
  })
})
