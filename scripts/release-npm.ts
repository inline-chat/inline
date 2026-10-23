import { existsSync } from "node:fs"
import { execFileSync } from "node:child_process"
import path from "node:path"
import { createInterface } from "node:readline/promises"
import { PACKAGE_CONFIGS as RELEASE_PACKAGES, parseReleaseTag } from "./ci/release-tag.mjs"
import { qualifyRelease } from "./ci/assert-release-commit.mjs"

const REPOSITORY = "inline-chat/inline"
const REPOSITORY_URL = "git+https://github.com/inline-chat/inline.git"
const WORKFLOW_FILE = "npm-publish.yml"
const WORKFLOW_ENVIRONMENT = "npm-publish"

export interface PackageConfig {
  key: string
  directory: string
  name: string
}

export interface ReleaseOptions {
  packageKey: string
  requestedVersion?: string
  requestedTag?: string
  dryRun: boolean
  watch: boolean
  yes: boolean
}

interface PackageManifest {
  name?: unknown
  version?: unknown
  private?: unknown
  repository?: {
    type?: unknown
    url?: unknown
    directory?: unknown
  }
  publishConfig?: {
    access?: unknown
  }
}

interface CommandResult {
  exitCode: number
  stdout: string
  stderr: string
}

export function isRegistryNotFound(output: string): boolean {
  return /\bE404\b/.test(output)
}

interface WorkflowRun {
  databaseId: number
  status: string
  conclusion: string
  headSha: string
  url: string
  createdAt?: string
}

export const PACKAGE_CONFIGS: Readonly<Record<string, PackageConfig>> = RELEASE_PACKAGES

const USAGE = `Usage: bun run release:npm <package> [options]

Packages:
  ${Object.keys(PACKAGE_CONFIGS).join("\n  ")}

Options:
  --version <version>  Release this version via <package>-v<version> (required)
  --tag <tag>          Require this dist-tag (derived when omitted)
  --dry-run            Run preflight checks without pushing a tag
  --no-watch           Push the tag without waiting for its workflow
  --yes                Skip the final interactive confirmation
  --help               Show this help

Examples:
  bun run release:npm hermes-agent --version 0.0.23-alpha.0 --dry-run
  bun run release:npm hermes-agent --version 0.0.6 --tag latest
  bun run release:npm openclaw --version 0.0.73-alpha.0 --yes`

export function parseReleaseArgs(argv: string[]): ReleaseOptions | { help: true } {
  if (argv.includes("--help") || argv.includes("-h")) return { help: true }

  let packageKey: string | undefined
  let requestedVersion: string | undefined
  let requestedTag: string | undefined
  let dryRun = false
  let watch = true
  let yes = false

  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index]
    if (argument === "--") continue
    if (argument === "--dry-run") {
      dryRun = true
      continue
    }
    if (argument === "--no-watch") {
      watch = false
      continue
    }
    if (argument === "--yes") {
      yes = true
      continue
    }
    if (argument === "--version" || argument === "--tag") {
      const value = argv[index + 1]
      if (!value || value.startsWith("--")) {
        throw new Error(`${argument} requires a value`)
      }
      if (argument === "--version") requestedVersion = value
      else requestedTag = value
      index += 1
      continue
    }
    if (argument.startsWith("--")) throw new Error(`Unknown option: ${argument}`)
    if (packageKey) throw new Error(`Unexpected positional argument: ${argument}`)
    packageKey = argument
  }

  if (!packageKey) throw new Error("A package key is required")
  if (!PACKAGE_CONFIGS[packageKey]) {
    throw new Error(`Unsupported package key: ${packageKey}`)
  }

  return { packageKey, requestedVersion, requestedTag, dryRun, watch, yes }
}

export function expectedDistTag(version: string): string {
  return parseReleaseTag(`protocol-v${version}`, "npm").channel
}

export function resolveDistTag(version: string, requestedTag?: string): string {
  const expected = expectedDistTag(version)
  if (requestedTag && requestedTag !== expected) {
    throw new Error(`Version ${version} must use the ${expected} dist-tag, not ${requestedTag}`)
  }
  return expected
}

export function validateManifest(
  config: PackageConfig,
  manifest: PackageManifest,
  requestedVersion?: string,
): string {
  if (manifest.name !== config.name) {
    throw new Error(`Manifest name mismatch: expected ${config.name}, found ${String(manifest.name)}`)
  }
  if (manifest.private === true) throw new Error(`${config.name} is marked private`)
  if (typeof manifest.version !== "string") throw new Error(`${config.name} has no valid version`)
  expectedDistTag(manifest.version)
  if (requestedVersion) expectedDistTag(requestedVersion)
  if (manifest.repository?.url !== REPOSITORY_URL) {
    throw new Error(`${config.name} repository URL must be ${REPOSITORY_URL}`)
  }
  if (manifest.repository?.directory !== config.directory) {
    throw new Error(
      `${config.name} repository directory must be ${config.directory}, found ${String(manifest.repository?.directory)}`,
    )
  }
  if (manifest.publishConfig?.access !== "public") {
    throw new Error(`${config.name} publishConfig.access must be public`)
  }
  return requestedVersion ?? manifest.version
}

export function parseWorkflowRunUrl(output: string): { id: number; url: string } | undefined {
  const match = output.match(/(https:\/\/github\.com\/inline-chat\/inline\/actions\/runs\/(\d+))/)
  if (!match) return undefined
  return { id: Number(match[2]), url: match[1] }
}

async function runCommand(
  arguments_: string[],
  options: { cwd: string; inherit?: boolean },
): Promise<CommandResult> {
  const process = Bun.spawn(arguments_, {
    cwd: options.cwd,
    stdin: options.inherit ? "inherit" : "ignore",
    stdout: options.inherit ? "inherit" : "pipe",
    stderr: options.inherit ? "inherit" : "pipe",
  })
  if (options.inherit) {
    const exitCode = await process.exited
    return { exitCode, stdout: "", stderr: "" }
  }

  const [stdout, stderr, exitCode] = await Promise.all([
    new Response(process.stdout).text(),
    new Response(process.stderr).text(),
    process.exited,
  ])
  return { exitCode, stdout: stdout.trim(), stderr: stderr.trim() }
}

async function requireCommand(arguments_: string[], cwd: string): Promise<string> {
  const result = await runCommand(arguments_, { cwd })
  if (result.exitCode !== 0) {
    throw new Error(
      `Command failed: ${arguments_.join(" ")}\n${result.stderr || result.stdout}`.trim(),
    )
  }
  return result.stdout
}

function parseJson<T>(value: string, description: string): T {
  try {
    return JSON.parse(value) as T
  } catch {
    throw new Error(`Could not parse ${description} JSON`)
  }
}

function assertOriginRemote(remote: string): void {
  const allowed = new Set([
    "https://github.com/inline-chat/inline.git",
    "git@github.com:inline-chat/inline.git",
    "ssh://git@github.com/inline-chat/inline.git",
  ])
  if (!allowed.has(remote)) {
    throw new Error(`origin must point to ${REPOSITORY}; found ${remote}`)
  }
}

async function assertMainCommit(repoRoot: string): Promise<string> {
  const branch = await requireCommand(["git", "branch", "--show-current"], repoRoot)
  if (branch !== "main") throw new Error(`Release must run from main; current branch is ${branch}`)

  assertOriginRemote(await requireCommand(["git", "remote", "get-url", "origin"], repoRoot))
  await requireCommand(["git", "fetch", "--quiet", "origin", "main"], repoRoot)

  const upstream = await requireCommand(
    ["git", "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"],
    repoRoot,
  )
  if (upstream !== "origin/main") {
    throw new Error(`main must track origin/main; current upstream is ${upstream}`)
  }

  const head = await requireCommand(["git", "rev-parse", "HEAD"], repoRoot)
  // A pushed commit stays releasable after main moves on; unpushed work does not.
  const onMain = await runCommand(["git", "merge-base", "--is-ancestor", head, "origin/main"], { cwd: repoRoot })
  if (onMain.exitCode !== 0) {
    throw new Error(`Local HEAD ${head.slice(0, 8)} is not on origin/main; push it first`)
  }
  return head
}

async function assertWorkflowAvailable(repoRoot: string): Promise<void> {
  const localWorkflow = path.join(repoRoot, ".github", "workflows", WORKFLOW_FILE)
  if (!existsSync(localWorkflow)) throw new Error(`Missing ${localWorkflow}`)
  await requireCommand(
    ["gh", "workflow", "view", WORKFLOW_FILE, "--repo", REPOSITORY, "--yaml"],
    repoRoot,
  )
}

async function assertSuccessfulCi(repoRoot: string, head: string): Promise<void> {
  qualifyRelease({ tag: "", commit: head, surface: "npm", allowUntagged: true, repository: REPOSITORY,
    runGit: (...args: string[]) => execFileSync("git", args, { cwd: repoRoot, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] }).trim(),
  })
}

async function readRegistryState(
  repoRoot: string,
  packageName: string,
  version: string,
): Promise<Record<string, string>> {
  const versionResult = await runCommand(
    ["npm", "view", `${packageName}@${version}`, "version", "--json"],
    { cwd: repoRoot },
  )
  if (versionResult.exitCode === 0) {
    console.log(`${packageName}@${version} exists; the workflow will verify exact artifact identity before resuming`)
  }
  if (versionResult.exitCode !== 0 && !isRegistryNotFound(`${versionResult.stderr}\n${versionResult.stdout}`)) {
    throw new Error(`Could not check ${packageName}@${version}: ${versionResult.stderr}`)
  }

  const tagsResult = await runCommand(
    ["npm", "view", packageName, "dist-tags", "--json"],
    { cwd: repoRoot },
  )
  if (tagsResult.exitCode !== 0) {
    if (isRegistryNotFound(`${tagsResult.stderr}\n${tagsResult.stdout}`)) return {}
    throw new Error(`Could not check ${packageName} dist-tags: ${tagsResult.stderr}`)
  }
  return parseJson<Record<string, string>>(tagsResult.stdout, `${packageName} dist-tags`)
}

async function confirmRelease(summary: string): Promise<void> {
  if (!process.stdin.isTTY) throw new Error("Interactive confirmation requires a TTY; pass --yes")
  const readline = createInterface({ input: process.stdin, output: process.stdout })
  try {
    const answer = await readline.question(`${summary}\nPublish now? [y/N] `)
    if (!/^y(?:es)?$/i.test(answer.trim())) throw new Error("Release cancelled")
  } finally {
    readline.close()
  }
}

async function findDispatchedRun(
  repoRoot: string,
  head: string,
  releaseTag: string,
  dispatchedAfter: number,
): Promise<{ id: number; url: string } | undefined> {
  for (let attempt = 0; attempt < 10; attempt += 1) {
    const output = await requireCommand(
      [
        "gh",
        "run",
        "list",
        "--repo",
        REPOSITORY,
        "--workflow",
        WORKFLOW_FILE,
        "--branch",
        releaseTag,
        "--event",
        "push",
        "--limit",
        "10",
        "--json",
        "databaseId,status,conclusion,headSha,url,createdAt",
      ],
      repoRoot,
    )
    const runs = parseJson<WorkflowRun[]>(output, "npm publish workflow runs")
    const run = runs.find(
      (candidate) =>
        candidate.headSha === head &&
        candidate.createdAt &&
        Date.parse(candidate.createdAt) >= dispatchedAfter - 5_000,
    )
    if (run) return { id: run.databaseId, url: run.url }
    await Bun.sleep(1_000)
  }
  return undefined
}

async function verifyPublishedVersion(
  repoRoot: string,
  packageName: string,
  version: string,
  tag: string,
): Promise<void> {
  const published = await requireCommand(
    ["npm", "view", `${packageName}@${version}`, "version"],
    repoRoot,
  )
  const tagged = await requireCommand(
    ["npm", "view", packageName, `dist-tags.${tag}`],
    repoRoot,
  )
  if (published !== version) {
    throw new Error(
      `Registry verification mismatch: version=${published || "missing"}, ${tag}=${tagged || "missing"}`,
    )
  }
  if (tagged !== version) console.log(`${tag} is now ${tagged || "unset"}; the verified release version remains available`)
}

async function main(): Promise<void> {
  const parsed = parseReleaseArgs(process.argv.slice(2))
  if ("help" in parsed) {
    console.log(USAGE)
    return
  }

  if (!parsed.requestedVersion) throw new Error("--version is required; release versions come from tags, not version-bump commits")
  const repoRoot = path.resolve(import.meta.dir, "..")
  const config = PACKAGE_CONFIGS[parsed.packageKey]
  const releaseTag = `${config.key}-v${parsed.requestedVersion}`
  parseReleaseTag(releaseTag, "npm")
  console.log(`Preflighting ${releaseTag} from ${REPOSITORY}`)

  const head = await assertMainCommit(repoRoot)
  await assertWorkflowAvailable(repoRoot)
  const manifest = parseJson<PackageManifest>(await requireCommand(
    ["git", "show", `${head}:${config.directory}/package.json`], repoRoot), "committed package manifest")
  const version = validateManifest(config, manifest, parsed.requestedVersion)
  const tag = resolveDistTag(version, parsed.requestedTag)
  const currentTags = await readRegistryState(repoRoot, config.name, version)
  await assertSuccessfulCi(repoRoot, head)
  const remote = await requireCommand(["git", "ls-remote", "origin", `refs/tags/${releaseTag}`, `refs/tags/${releaseTag}^{}`], repoRoot)
  const existingRefs = remote.split("\n").filter(Boolean).map((line) => line.split(/\s+/))
  const existing = existingRefs.length > 0
  const target = existingRefs.find((entry) => entry[1]?.endsWith("^{}")) ?? existingRefs[0]
  if (target && target[0] !== head) throw new Error(`Immutable tag ${releaseTag} already points to another commit`)

  console.log(`Package: ${config.name}`)
  console.log(`Version: ${version}; npm channel: ${tag} (currently ${currentTags[tag] ?? "unset"})`)
  console.log(`Commit: ${head}; Git tag: ${releaseTag}`)
  console.log(`Workflow: ${WORKFLOW_FILE}, environment ${WORKFLOW_ENVIRONMENT}`)
  if (parsed.dryRun) {
    console.log("Dry run complete; no tag was pushed")
    return
  }
  if (!parsed.yes) await confirmRelease(`Push ${releaseTag} to release ${config.name}@${version} on ${tag}`)

  const dispatchedAfter = existing ? 0 : Date.now()
  if (!existing) await requireCommand(["git", "push", "origin", `${head}:refs/tags/${releaseTag}`], repoRoot)
  const run = await findDispatchedRun(repoRoot, head, releaseTag, dispatchedAfter)
  if (!run) throw new Error("Tag exists, but its run was not found; check GitHub Actions before retrying")
  if (existing) {
    const state = parseJson<WorkflowRun>(await requireCommand(["gh", "run", "view", String(run.id), "--repo", REPOSITORY, "--json", "status,conclusion"], repoRoot), "existing workflow run")
    if (state.status === "completed" && state.conclusion !== "success") {
      await requireCommand(["gh", "run", "rerun", String(run.id), "--repo", REPOSITORY, "--failed"], repoRoot)
    }
  }
  console.log(`Release run: ${run.url}`)

  if (!parsed.watch) return
  const watched = await runCommand(
    ["gh", "run", "watch", String(run.id), "--repo", REPOSITORY, "--exit-status"],
    { cwd: repoRoot, inherit: true },
  )
  if (watched.exitCode !== 0) {
    throw new Error(`Publish workflow failed: ${run.url}`)
  }
  await verifyPublishedVersion(repoRoot, config.name, version, tag)
  console.log(`Published ${config.name}@${version} on ${tag}`)
}

if (import.meta.main) {
  main().catch((error: unknown) => {
    const message = error instanceof Error ? error.message : String(error)
    console.error(`release:npm: ${message}`)
    process.exitCode = 1
  })
}
