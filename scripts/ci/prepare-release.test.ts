import { afterEach, describe, expect, test } from "bun:test"
import { execFileSync } from "node:child_process"
import { mkdtemp, mkdir, readFile, rm, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join, resolve } from "node:path"
import { planReleaseVersion, prepareReleaseTag } from "../prepare-release"
import { PACKAGE_CONFIGS } from "./release-tag.mjs"

const directories: string[] = []
afterEach(async () => { await Promise.all(directories.splice(0).map((dir) => rm(dir, { recursive: true, force: true }))) })
const env = { ...process.env, GIT_CONFIG_NOSYSTEM: "1", GIT_CONFIG_GLOBAL: "/dev/null", GIT_TERMINAL_PROMPT: "0" }
const command = (cwd: string, ...args: string[]) => execFileSync("git", args, { cwd, env, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] }).trim()
const tag = "bot-api-types-v0.1.4-alpha.1"

async function fixture() {
  const directory = await mkdtemp(join(tmpdir(), "inline-version-commit-test-"))
  directories.push(directory)
  const source = join(directory, "source"), origin = join(directory, "origin.git")
  command(directory, "init", "--bare", "--initial-branch=main", origin)
  command(directory, "init", "--initial-branch=main", source)
  const git = (...args: string[]) => command(source, ...args)
  git("config", "user.name", "Release fixture")
  git("config", "user.email", "release-fixture@example.invalid")
  git("config", "core.hooksPath", "/dev/null")
  git("remote", "add", "origin", origin)
  const pkg = join(source, "packages/bot-api-types/package.json")
  await mkdir(join(pkg, ".."), { recursive: true })
  const manifest = { name: "@inline-chat/bot-api-types", version: "0.1.3-alpha.0",
    repository: { url: "git+https://github.com/inline-chat/inline.git", directory: "packages/bot-api-types" },
    publishConfig: { access: "public" }, dependencies: { external: "1.2.3" } }
  await writeFile(pkg, JSON.stringify(manifest, null, 2) + "\n")
  await writeFile(join(source, "bun.lock"), '{\n  "workspaces": {\n    "packages/bot-api-types": {\n      "name": "@inline-chat/bot-api-types",\n      "version": "0.1.3-alpha.0",\n    },\n  },\n}\n')
  git("add", "."); git("commit", "-m", "fixture source"); git("push", "origin", "main")
  const initial = git("rev-parse", "HEAD")
  // Only the trusted-remote spelling is substituted. Commit, status, fetch,
  // ancestry, pushes and annotated tags all run against a real local Git server.
  const runGit = (...args: string[]) => args.join(" ") === "remote get-url origin" ? "https://github.com/inline-chat/inline.git" : git(...args)
  const remote = (...args: string[]) => command(directory, "--git-dir", origin, ...args)
  const remoteTags = () => git("ls-remote", "origin", `refs/tags/${tag}`, `refs/tags/${tag}^{}`)
  return { source, origin, git, runGit, remote, remoteTags, initial, pkg, manifest }
}

describe("automated version commits and immutable tags", () => {
  const gitTest = (name: string, run: () => Promise<void>) => test(name, run, 20_000)
  gitTest("previews without writing source, commits or tags", async () => {
    const f = await fixture()
    const before = await readFile(f.pkg, "utf8")
    await prepareReleaseTag(f.source, tag, { dryRun: true, runGit: f.runGit, waitForCi: async () => { throw new Error("must not wait") } })
    expect(await readFile(f.pkg, "utf8")).toBe(before)
    expect(f.git("rev-parse", "HEAD")).toBe(f.initial)
    expect(f.remoteTags()).toBe("")
    expect(f.git("status", "--porcelain")).toBe("")
  })

  gitTest("pushes the exact version commit before CI and tags that commit after main advances", async () => {
    const f = await fixture()
    const result = await prepareReleaseTag(f.source, tag, { yes: true, runGit: f.runGit, waitForCi: async (_root, sha, surface) => {
      expect(surface).toBe("npm")
      expect(f.remote("rev-parse", "refs/heads/main")).toBe(sha)
      expect(f.remoteTags()).toBe("")
      const committed = JSON.parse(f.remote("show", `${sha}:packages/bot-api-types/package.json`))
      expect(committed).toEqual({ ...f.manifest, version: "0.1.4-alpha.1" })
      expect(f.git("show", "--format=", "--name-only", sha).split("\n").sort()).toEqual(["bun.lock", "packages/bot-api-types/package.json"])
      const sibling = join(f.source, "../sibling")
      command(f.source, "clone", f.origin, sibling)
      command(sibling, "config", "user.name", "Sibling fixture")
      command(sibling, "config", "user.email", "sibling@example.invalid")
      command(sibling, "config", "core.hooksPath", "/dev/null")
      await writeFile(join(sibling, "newer.txt"), "main moved during CI")
      command(sibling, "add", "newer.txt"); command(sibling, "commit", "-m", "newer source"); command(sibling, "push", "origin", "main")
    } })
    expect(result.sha).not.toBe(f.initial)
    expect(f.remote("rev-parse", `${tag}^{commit}`)).toBe(result.sha)
    expect(f.remote("cat-file", "-t", `refs/tags/${tag}`)).toBe("tag")
    expect(f.remote("rev-parse", "refs/heads/main")).not.toBe(result.sha)
    expect(f.git("status", "--porcelain")).toBe("")
  })

  gitTest("resumes a failed CI check without duplicating a commit or creating an early tag", async () => {
    const f = await fixture()
    await expect(prepareReleaseTag(f.source, tag, { yes: true, runGit: f.runGit, waitForCi: async () => { throw new Error("CI failed") } })).rejects.toThrow("CI failed")
    const versionCommit = f.git("rev-parse", "HEAD")
    expect(f.remote("rev-parse", "refs/heads/main")).toBe(versionCommit)
    expect(f.remoteTags()).toBe("")
    const result = await prepareReleaseTag(f.source, tag, { yes: true, runGit: f.runGit, waitForCi: async () => {} })
    expect(result.sha).toBe(versionCommit)
    expect(f.git("rev-list", "--count", "HEAD")).toBe("2")
    await prepareReleaseTag(f.source, tag, { yes: true, runGit: f.runGit, waitForCi: async () => {} })
    expect(f.git("rev-list", "--count", "HEAD")).toBe("2")
  })

  gitTest("resumes a rejected main push with the same version commit", async () => {
    const f = await fixture()
    const failMainPush = (...args: string[]) => {
      if (args[0] === "push" && args[2]?.endsWith(":refs/heads/main")) throw new Error("main push rejected")
      return f.runGit(...args)
    }
    await expect(prepareReleaseTag(f.source, tag, { yes: true, runGit: failMainPush, waitForCi: async () => {} })).rejects.toThrow("main push rejected")
    const versionCommit = f.git("rev-parse", "HEAD")
    expect(f.remote("rev-parse", "refs/heads/main")).toBe(f.initial)
    const result = await prepareReleaseTag(f.source, tag, { yes: true, runGit: f.runGit, waitForCi: async () => {} })
    expect(result.sha).toBe(versionCommit)
    expect(f.git("rev-list", "--count", "HEAD")).toBe("2")
  })

  gitTest("commits CLI workspace, internal requirements and lock versions together", async () => {
    const f = await fixture()
    await mkdir(join(f.source, "cli"))
    await mkdir(join(f.source, "crates/sdk"), { recursive: true })
    await writeFile(join(f.source, "Cargo.toml"), '[workspace]\nmembers = ["cli", "crates/sdk"]\n[workspace.package]\nversion = "0.7.18"\n')
    await writeFile(join(f.source, "cli/Cargo.toml"), '[package]\nname = "inline-cli"\nversion.workspace = true\n[dependencies]\ninline-sdk = { path = "../crates/sdk", version = "0.7.18" }\n')
    await writeFile(join(f.source, "crates/sdk/Cargo.toml"), '[package]\nname = "inline-sdk"\nversion.workspace = true\n')
    await writeFile(join(f.source, "Cargo.lock"), 'version = 4\n\n[[package]]\nname = "inline-cli"\nversion = "0.7.18"\n\n[[package]]\nname = "inline-sdk"\nversion = "0.7.18"\n')
    f.git("add", "Cargo.toml", "Cargo.lock", "cli", "crates"); f.git("commit", "-m", "CLI source"); f.git("push", "origin", "main")
    const result = await prepareReleaseTag(f.source, "cli-v0.7.19-alpha.1", { yes: true, runGit: f.runGit, waitForCi: async (_root, sha, surface) => {
      expect(surface).toBe("cli")
      expect(f.remote("show", `${sha}:Cargo.lock`)).toContain('version = "0.7.19-alpha.1"')
      expect(f.remote("show", `${sha}:cli/Cargo.toml`)).toContain('version = "0.7.19-alpha.1"')
    } })
    expect(f.remote("rev-parse", "cli-v0.7.19-alpha.1^{commit}")).toBe(result.sha)
    expect(f.git("show", "--format=", "--name-only", result.sha).split("\n").sort()).toEqual(["Cargo.lock", "Cargo.toml", "cli/Cargo.toml"])
    expect(JSON.parse(await readFile(f.pkg, "utf8"))).toEqual(f.manifest)
  })

  gitTest("reuses an annotated local tag after its push failed", async () => {
    const f = await fixture()
    const failTagPush = (...args: string[]) => {
      if (args[0] === "push" && args[2]?.startsWith("refs/tags/")) throw new Error("tag push rejected")
      return f.runGit(...args)
    }
    await expect(prepareReleaseTag(f.source, tag, { yes: true, runGit: failTagPush, waitForCi: async () => {} })).rejects.toThrow("tag push rejected")
    const object = f.git("rev-parse", `refs/tags/${tag}`)
    expect(f.remoteTags()).toBe("")
    await prepareReleaseTag(f.source, tag, { yes: true, runGit: f.runGit, waitForCi: async () => {} })
    expect(f.remote("rev-parse", `refs/tags/${tag}`)).toBe(object)
  })

  gitTest("resumes a remote tag after main advances without moving it or touching user work", async () => {
    const f = await fixture()
    await writeFile(f.pkg, "uncommitted user change")
    await expect(prepareReleaseTag(f.source, tag, { yes: true, runGit: f.runGit })).rejects.toThrow("clean tracked files")
    f.git("add", "packages/bot-api-types/package.json")
    await expect(prepareReleaseTag(f.source, tag, { yes: true, runGit: f.runGit })).rejects.toThrow("clean tracked files")
    f.git("restore", "--staged", "packages/bot-api-types/package.json"); f.git("restore", "packages/bot-api-types/package.json")
    f.git("tag", "-a", tag, "-m", "older release"); f.git("push", "origin", tag)
    await writeFile(join(f.source, "newer.txt"), "source")
    f.git("add", "newer.txt"); f.git("commit", "-m", "new source"); f.git("push", "origin", "main")
    const sha = f.git("rev-parse", "HEAD")
    await writeFile(f.pkg, "new user work")
    const result = await prepareReleaseTag(f.source, tag, { yes: true, runGit: f.runGit, waitForCi: async (_root, candidate) => { expect(candidate).toBe(f.initial) } })
    expect(result).toMatchObject({ sha: f.initial, existing: true })
    expect(f.git("rev-parse", "HEAD")).toBe(sha)
    expect(f.remote("rev-parse", `${tag}^{commit}`)).toBe(f.initial)
    expect(await readFile(f.pkg, "utf8")).toBe("new user work")
  })

  gitTest("never rewrites a conflicting local tag", async () => {
    const f = await fixture()
    f.git("tag", "-a", tag, "-m", "local conflict")
    const object = f.git("rev-parse", `refs/tags/${tag}`)
    await expect(prepareReleaseTag(f.source, tag, { yes: true, runGit: f.runGit, waitForCi: async () => {} })).rejects.toThrow("Conflicting local tag")
    expect(f.git("rev-parse", `refs/tags/${tag}`)).toBe(object)
    expect(f.remoteTags()).toBe("")
  })

  gitTest("does not tag if the checkout changes while CI is running", async () => {
    const f = await fixture()
    await expect(prepareReleaseTag(f.source, tag, { yes: true, runGit: f.runGit, waitForCi: async () => { await writeFile(f.pkg, "new user edit") } })).rejects.toThrow("Checkout changed")
    expect(f.remoteTags()).toBe("")
    expect(await readFile(f.pkg, "utf8")).toBe("new user edit")
  })
})

test("plans the seven real npm packages with unchanged dependency requirements and runtime versions aligned", async () => {
  const root = resolve(import.meta.dir, "../..")
  for (const config of Object.values(PACKAGE_CONFIGS)) {
    const edits = await planReleaseVersion(root, `${config.key}-v9.9.9-alpha.1`)
    const file = resolve(root, config.directory, "package.json")
    const source = JSON.parse(await readFile(file, "utf8"))
    expect(JSON.parse(edits.get(file)!)).toEqual({ ...source, version: "9.9.9-alpha.1" })
    const lock = edits.get(resolve(root, "bun.lock"))!
    expect(lock).toContain(`"${config.directory}": {\n      "name": "${config.name}",\n      "version": "9.9.9-alpha.1"`)
    expect(edits.size).toBe(config.key === "hermes-agent" ? 4 : config.key === "openclaw" ? 3 : 2)
    if (config.key === "openclaw") {
      const readme = edits.get(resolve(root, config.directory, "README.md"))!
      expect(readme).toContain("| `9.9.9-alpha.1` |")
      expect(readme).toContain("| Prerelease |")
      expect([...readme.matchAll(/^\| `(\d+\.\d+\.\d+(?:-[\w.-]+)?)` \|/gm)]).toHaveLength(6)
    }
    if (config.key === "hermes-agent") {
      expect(edits.get(resolve(root, config.directory, "plugin/inline/plugin.yaml"))).toContain("version: 9.9.9-alpha.1")
      expect(edits.get(resolve(root, config.directory, "plugin/inline/cli.py"))).toContain('inline-hermes-agent-adapter/9.9.9-alpha.1"')
    }
    expect(JSON.parse(await readFile(file, "utf8"))).toEqual(source)
  }
})
