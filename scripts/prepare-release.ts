import { execFileSync } from "node:child_process"
import { readFile, writeFile } from "node:fs/promises"
import { relative, resolve } from "node:path"
import { createInterface } from "node:readline/promises"
import { parseReleaseTag } from "./ci/release-tag.mjs"
import { qualifyRelease, ReleaseGateError } from "./ci/assert-release-commit.mjs"
import { planCliReleaseVersion } from "./ci/cli-release-version"
import { validateSourceManifest } from "./ci/npm-release-preflight.mjs"

const repository = "inline-chat/inline"
const root = resolve(import.meta.dir, "..")
const escape = (value: string) => value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")

export async function planReleaseVersion(repoRoot: string, tag: string) {
  const release = parseReleaseTag(tag)
  if (release.surface === "cli") return (await planCliReleaseVersion(repoRoot, tag)).edits
  const file = resolve(repoRoot, release.directory, "package.json")
  const source = await readFile(file, "utf8")
  const manifest = JSON.parse(source)
  validateSourceManifest({ ...manifest, version: release.version }, release)
  const edits = new Map([[file, source.replace(/^(\s*"version":\s*)"[^"]+"/m, `$1"${release.version}"`)]])
  if (JSON.parse(edits.get(file)!).version !== release.version) throw new Error("Expected a package version field")

  // Bun records each workspace's version separately. Change only that entry;
  // dependency requirements and resolved registry packages remain untouched.
  const lock = resolve(repoRoot, "bun.lock")
  const contents = await readFile(lock, "utf8")
  const entry = new RegExp(`(^    "${escape(release.directory)}": \\{\\n      "name": "${escape(release.name)}",\\n      "version": )"[^"]+"`, "gm")
  if ([...contents.matchAll(entry)].length !== 1) throw new Error("Expected one Bun workspace version entry")
  edits.set(lock, contents.replace(entry, `$1"${release.version}"`))

  if (release.packageKey === "openclaw") {
    // Keep the current compatibility line plus five prior lines, as required by
    // the plugin's source contract. Stable installation examples stay intact.
    const readme = resolve(repoRoot, release.directory, "README.md")
    const markdown = await readFile(readme, "utf8")
    const rows = [...markdown.matchAll(/^\| `(\d+\.\d+\.\d+(?:-[\w.-]+)?)` \|[^\r\n]+$/gm)]
    if (rows.length !== 6 || rows[0]![1] !== manifest.version) throw new Error("OpenClaw compatibility history must start with its source version")
    if (manifest.version !== release.version) {
      const status = release.version.includes("-") ? "Prerelease" : "Stable"
      const current = rows[0]![0].replace(`\`${manifest.version}\``, `\`${release.version}\``).replace(/\| (?:Stable|Prerelease|Previous) \|/, `| ${status} |`)
      const history = [current, ...rows.map((row) => row[0])].slice(0, 6).join("\n")
      const start = rows[0]!.index!, end = rows.at(-1)!.index! + rows.at(-1)![0].length
      edits.set(readme, markdown.slice(0, start) + history + markdown.slice(end))
    }
  }

  if (release.packageKey === "hermes-agent") {
    const plugin = resolve(repoRoot, release.directory, "plugin/inline/plugin.yaml")
    const yaml = await readFile(plugin, "utf8")
    if (yaml.match(/^version:[^\r\n]*$/gm)?.length !== 1) throw new Error("Expected one Hermes plugin version")
    edits.set(plugin, yaml.replace(/^version:[^\r\n]*$/m, `version: ${release.version}`))
    const cli = resolve(repoRoot, release.directory, "plugin/inline/cli.py")
    const python = await readFile(cli, "utf8")
    const probe = /^_PROBE_USER_AGENT = (["'])inline-hermes-agent-adapter\/[^"'\r\n]+\1$/gm
    if (python.match(probe)?.length !== 1) throw new Error("Expected one Hermes probe version")
    edits.set(cli, python.replace(probe, `_PROBE_USER_AGENT = "inline-hermes-agent-adapter/${release.version}"`))
  }
  return edits
}

export function remoteTagCommit(output: string, tag: string): string | undefined {
  const refs = new Map(output.split("\n").filter(Boolean).map((line) => {
    const [sha, ref] = line.split(/\s+/)
    return [ref!, sha!] as const
  }))
  return refs.get(`refs/tags/${tag}^{}`) ?? refs.get(`refs/tags/${tag}`)
}

export async function waitForReleaseCi(repoRoot: string, sha: string, surface: string) {
  const deadline = Date.now() + 60 * 60_000
  console.log(`Waiting for ${surface} release checks on ${sha}`)
  while (true) {
    try {
      qualifyRelease({ tag: "", commit: sha, surface, allowUntagged: true, repository,
        runGit: (...args: string[]) => execFileSync("git", args, { cwd: repoRoot, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] }).trim(),
      })
      return
    } catch (error) {
      if (!(error instanceof ReleaseGateError) || error.outcome !== "deferred" || Date.now() >= deadline) throw error
      await Bun.sleep(15_000)
    }
  }
}

/** Commit versions first; only an exact green main commit receives a release tag. */
export async function prepareReleaseTag(repoRoot: string, tag: string, options: {
  dryRun?: boolean
  yes?: boolean
  waitForCi?: typeof waitForReleaseCi
  runGit?: (...args: string[]) => string
} = {}) {
  const release = parseReleaseTag(tag)
  const git = options.runGit ?? ((...args: string[]) => execFileSync("git", args, { cwd: repoRoot, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] }).trim())
  if (git("branch", "--show-current") !== "main") throw new Error("Prepare releases on main")
  const remote = git("remote", "get-url", "origin")
  if (!["https://github.com/inline-chat/inline.git", "git@github.com:inline-chat/inline.git", "ssh://git@github.com/inline-chat/inline.git"].includes(remote)) {
    throw new Error(`origin must point to ${repository}`)
  }
  git("fetch", "--no-tags", "origin", "main")
  let sha = git("rev-parse", "HEAD")
  const upstream = git("rev-parse", "FETCH_HEAD")
  const existingTag = () => remoteTagCommit(git("ls-remote", "origin", `refs/tags/${tag}`, `refs/tags/${tag}^{}`), tag)
  const existing = existingTag()
  const confirm = async () => {
    if (options.yes) return
    if (!process.stdin.isTTY) throw new Error("Pass --yes for an already-authorized release")
    const prompt = createInterface({ input: process.stdin, output: process.stdout })
    try {
      if (!/^y(?:es)?$/i.test((await prompt.question("Prepare and publish this release? [y/N] ")).trim())) throw new Error("Release cancelled")
    } finally { prompt.close() }
  }
  if (existing) {
    console.log(`Resume immutable ${tag} at ${existing}; source files and main stay unchanged`)
    if (!options.dryRun) {
      await confirm()
      await (options.waitForCi ?? waitForReleaseCi)(repoRoot, existing, release.surface)
      if (existingTag() !== existing) throw new Error("Remote release tag changed while checking CI")
    }
    return { sha: existing, tag, existing: true, dryRun: !!options.dryRun }
  }
  if (git("status", "--porcelain", "--untracked-files=no")) throw new Error("Release preparation requires clean tracked files and index; preserve other work in a separate checkout")

  const edits = await planReleaseVersion(repoRoot, tag)
  git("ls-files", "--error-unmatch", "--", ...[...edits.keys()].map((file) => relative(repoRoot, file)))
  const changed = new Map<string, string>()
  for (const [file, contents] of edits) {
    if (await readFile(file, "utf8") !== contents) changed.set(relative(repoRoot, file), contents)
  }
  const message = `release: ${release.packageKey} v${release.version}`
  const onMain = () => {
    try { git("merge-base", "--is-ancestor", sha, "origin/main"); return true } catch { return false }
  }
  if (changed.size && sha !== upstream) throw new Error("Update to origin/main before preparing a new version commit")
  if (!changed.size && !onMain() && !(git("log", "-1", "--format=%s") === message && git("rev-parse", "HEAD^") === upstream)) {
    throw new Error("Only a version commit created by this command may be resumed before it is pushed")
  }
  console.log(`${tag}: ${changed.size ? `commit ${[...changed.keys()].join(", ")}` : `use ${sha}`}; push main, wait for release checks, then push an annotated tag`)
  if (options.dryRun) return { sha, tag, existing: !!existing, dryRun: true }
  await confirm()
  if (git("rev-parse", "HEAD") !== sha || git("status", "--porcelain", "--untracked-files=no")) throw new Error("Checkout changed during release preparation")
  if (changed.size) {
    for (const [file, contents] of changed) await writeFile(resolve(repoRoot, file), contents)
    git("add", "--", ...changed.keys())
    git("diff", "--cached", "--check")
    git("commit", "-m", message)
    sha = git("rev-parse", "HEAD")
  }
  // If another main push wins the race, Git rejects this without rewriting it.
  // Keep the version commit for a retry; no tag has been created yet.
  if (!onMain()) git("push", "origin", `${sha}:refs/heads/main`)
  await (options.waitForCi ?? waitForReleaseCi)(repoRoot, sha, release.surface)
  if (git("rev-parse", "HEAD") !== sha || git("status", "--porcelain", "--untracked-files=no")) throw new Error("Checkout changed while waiting for CI; no tag was pushed")
  const remoteNow = existingTag()
  if (remoteNow && remoteNow !== sha) throw new Error(`Immutable tag ${tag} already points to another commit`)
  if (!remoteNow) {
    const local = git("tag", "--list", tag)
    if (local) {
      if (git("rev-parse", `${tag}^{commit}`) !== sha || git("cat-file", "-t", `refs/tags/${tag}`) !== "tag") throw new Error(`Conflicting local tag ${tag}; it will not be moved`)
    } else git("tag", "-a", tag, sha, "-m", `Release ${tag}`)
    git("push", "origin", `refs/tags/${tag}:refs/tags/${tag}`)
  }
  if (existingTag() !== sha) throw new Error("Remote release tag verification failed")
  return { sha, tag, existing: !!remoteNow, dryRun: false }
}

if (import.meta.main) {
  const [key, ...args] = process.argv.slice(2)
  const versionIndex = args.indexOf("--version")
  const version = args[versionIndex + 1]
  const allowed = args.filter((_, index) => index !== versionIndex && index !== versionIndex + 1)
  if (!key || versionIndex < 0 || !version || allowed.some((arg) => !["--dry-run", "--yes"].includes(arg))) {
    throw new Error("Usage: prepare-release.ts <cli|package-key> --version VERSION [--dry-run] [--yes]")
  }
  try {
    const result = await prepareReleaseTag(root, `${key}-v${version}`, { dryRun: args.includes("--dry-run"), yes: args.includes("--yes") })
    if (!result.dryRun && result.existing && key === "cli") {
      execFileSync("gh", ["workflow", "run", "cli-release.yml", "--repo", repository, "--ref", "main", "-f", `tag=${result.tag}`], { cwd: root, stdio: "inherit" })
    }
    console.log(result.dryRun ? "Dry run complete; no files, commits or tags changed" : `${result.tag} queued: https://github.com/${repository}/actions`)
  } catch (error) {
    console.error(`Release preparation failed: ${error instanceof Error ? error.message : String(error)}. Any version commit remains available; rerun the same command after resolving the failure.`)
    process.exitCode = 1
  }
}
