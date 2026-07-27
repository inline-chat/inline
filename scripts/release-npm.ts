import { existsSync } from "node:fs"
import { readFile } from "node:fs/promises"
import path from "node:path"
import { createInterface } from "node:readline/promises"

const REPOSITORY = "inline-chat/inline"
const REPOSITORY_URL = "git+https://github.com/inline-chat/inline.git"
const WORKFLOW_FILE = "npm-publish.yml"
const WORKFLOW_ENVIRONMENT = "npm-publish"
const ALLOWED_TAGS = new Set(["latest", "alpha", "beta", "next"])

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

interface WorkflowRun {
  databaseId: number
  status: string
  conclusion: string
  headSha: string
  url: string
  createdAt?: string
}

export const PACKAGE_CONFIGS: Readonly<Record<string, PackageConfig>> = {
  protocol: {
    key: "protocol",
    directory: "packages/protocol",
    name: "@inline-chat/protocol",
  },
  "bot-api-types": {
    key: "bot-api-types",
    directory: "packages/bot-api-types",
    name: "@inline-chat/bot-api-types",
  },
  "bot-api": {
    key: "bot-api",
    directory: "packages/bot-api",
    name: "@inline-chat/bot-api",
  },
  "realtime-sdk": {
    key: "realtime-sdk",
    directory: "sdk",
    name: "@inline-chat/realtime-sdk",
  },
  openclaw: {
    key: "openclaw",
    directory: "openclaw",
    name: "@inline-openclaw/inline",
  },
  "hermes-agent": {
    key: "hermes-agent",
    directory: "hermes-agent",
    name: "@inline-chat/hermes-agent-adapter",
  },
}

const USAGE = `Usage: bun run release:npm <package> [options]

Packages:
  ${Object.keys(PACKAGE_CONFIGS).join("\n  ")}

Options:
  --version <version>  Require this exact package.json version
  --tag <tag>          Require this dist-tag (derived when omitted)
  --dry-run            Run every preflight check without dispatching
  --no-watch           Dispatch without waiting for the workflow
  --yes                Skip the final interactive confirmation
  --help               Show this help

Examples:
  bun run release:npm hermes-agent --dry-run
  bun run release:npm hermes-agent --version 0.0.6 --tag latest
  bun run release:npm openclaw --yes`

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
  const match = version.match(
    /^\d+\.\d+\.\d+(?:-([0-9A-Za-z-]+)(?:\.[0-9A-Za-z-]+)*)?(?:\+[0-9A-Za-z.-]+)?$/,
  )
  if (!match) throw new Error(`Invalid semantic version: ${version}`)

  const tag = match[1] ?? "latest"
  if (!ALLOWED_TAGS.has(tag)) {
    throw new Error(
      `Version ${version} derives unsupported dist-tag ${tag}; expected latest, alpha, beta, or next`,
    )
  }
  return tag
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
  if (requestedVersion && requestedVersion !== manifest.version) {
    throw new Error(
      `Version mismatch: package.json has ${manifest.version}, requested ${requestedVersion}`,
    )
  }
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
  return manifest.version
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

async function assertCleanAndSynced(repoRoot: string): Promise<string> {
  const status = await requireCommand(
    ["git", "status", "--porcelain=v1", "--untracked-files=all"],
    repoRoot,
  )
  if (status) throw new Error(`Worktree must be clean before publishing:\n${status}`)

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
  const remoteHead = await requireCommand(["git", "rev-parse", "origin/main"], repoRoot)
  if (head !== remoteHead) {
    throw new Error(`Local HEAD ${head.slice(0, 8)} does not match origin/main ${remoteHead.slice(0, 8)}`)
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
  const output = await requireCommand(
    [
      "gh",
      "run",
      "list",
      "--repo",
      REPOSITORY,
      "--workflow",
      "CI",
      "--commit",
      head,
      "--limit",
      "10",
      "--json",
      "databaseId,status,conclusion,headSha,url",
    ],
    repoRoot,
  )
  const runs = parseJson<WorkflowRun[]>(output, "GitHub CI runs").filter(
    (run) => run.headSha === head,
  )
  if (runs.some((run) => run.status === "completed" && run.conclusion === "success")) return

  const active = runs.find((run) => run.status === "queued" || run.status === "in_progress")
  if (active) {
    console.log(`Waiting for CI on ${head.slice(0, 8)}: ${active.url}`)
    const result = await runCommand(
      ["gh", "run", "watch", String(active.databaseId), "--repo", REPOSITORY, "--exit-status"],
      { cwd: repoRoot, inherit: true },
    )
    if (result.exitCode === 0) return
    throw new Error(`CI failed for ${head.slice(0, 8)}: ${active.url}`)
  }

  const failed = runs[0]
  if (failed) {
    throw new Error(
      `CI is not green for ${head.slice(0, 8)} (${failed.conclusion || failed.status}): ${failed.url}`,
    )
  }
  throw new Error(`No CI run found for ${head.slice(0, 8)}`)
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
    throw new Error(`${packageName}@${version} already exists on npm`)
  }
  if (!/E404|No match found|not found/i.test(`${versionResult.stderr}\n${versionResult.stdout}`)) {
    throw new Error(`Could not check ${packageName}@${version}: ${versionResult.stderr}`)
  }

  const tags = await requireCommand(
    ["npm", "view", packageName, "dist-tags", "--json"],
    repoRoot,
  )
  return parseJson<Record<string, string>>(tags, `${packageName} dist-tags`)
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
  if (published !== version || tagged !== version) {
    throw new Error(
      `Registry verification mismatch: version=${published || "missing"}, ${tag}=${tagged || "missing"}`,
    )
  }
}

async function main(): Promise<void> {
  const parsed = parseReleaseArgs(process.argv.slice(2))
  if ("help" in parsed) {
    console.log(USAGE)
    return
  }

  const repoRoot = path.resolve(import.meta.dir, "..")
  const config = PACKAGE_CONFIGS[parsed.packageKey]
  console.log(`Preflighting ${config.name} from ${REPOSITORY}`)

  await requireCommand(["gh", "auth", "status"], repoRoot)
  const head = await assertCleanAndSynced(repoRoot)
  await assertWorkflowAvailable(repoRoot)

  const manifestPath = path.join(repoRoot, config.directory, "package.json")
  const manifest = parseJson<PackageManifest>(await readFile(manifestPath, "utf8"), manifestPath)
  const version = validateManifest(config, manifest, parsed.requestedVersion)
  const tag = resolveDistTag(version, parsed.requestedTag)
  const currentTags = await readRegistryState(repoRoot, config.name, version)
  await assertSuccessfulCi(repoRoot, head)

  console.log(`Package: ${config.name}`)
  console.log(`Version: ${version} (not yet published)`)
  console.log(`Dist-tag: ${tag} (currently ${currentTags[tag] ?? "unset"})`)
  console.log(`Commit: ${head}`)
  console.log(`Workflow: ${WORKFLOW_FILE}, environment ${WORKFLOW_ENVIRONMENT}`)

  if (parsed.dryRun) {
    console.log("Dry run complete; no workflow was dispatched")
    return
  }
  if (!parsed.yes) {
    await confirmRelease(`Release ${config.name}@${version} to npm dist-tag ${tag}`)
  }

  const dispatchedAfter = Date.now()
  const dispatch = await requireCommand(
    [
      "gh",
      "workflow",
      "run",
      WORKFLOW_FILE,
      "--repo",
      REPOSITORY,
      "--ref",
      "main",
      "-f",
      `package=${config.key}`,
      "-f",
      `version=${version}`,
      "-f",
      `tag=${tag}`,
      "-f",
      `commit=${head}`,
    ],
    repoRoot,
  )
  const run = parseWorkflowRunUrl(dispatch) ?? (await findDispatchedRun(repoRoot, head, dispatchedAfter))
  if (!run) {
    throw new Error("Workflow dispatched, but its run ID could not be resolved; inspect GitHub Actions")
  }
  console.log(`Dispatched: ${run.url}`)

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
