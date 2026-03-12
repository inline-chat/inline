import { existsSync } from "node:fs"
import { isAbsolute, resolve } from "node:path"
import { version } from "../package.json"
import { buildServerSentryDist, buildServerSentryRelease } from "../src/utils/sentryRelease"

const helpText = [
  "Usage: bun run server/scripts/upload-sourcemaps.ts [options]",
  "",
  "Options:",
  "  --dist-dir <path>     Build output directory. Default: server/dist",
  "  --commit <sha>        Commit SHA used for Sentry release/dist. Defaults to SOURCE_COMMIT.",
  "  --auth-token <token>  Sentry auth token. Defaults to SENTRY_AUTH_TOKEN.",
  "  --org <slug>          Sentry org slug. Default: usenoor",
  "  --project <slug>      Sentry project slug. Default: inline-server",
  "  --url <url>           Sentry base URL. Default: https://us.sentry.io",
  "  --dry-run             Print the resolved upload commands without executing them.",
  "  --help                Show this help text.",
].join("\n")

function resolveInputPath(pathValue: string): string {
  return isAbsolute(pathValue) ? pathValue : resolve(process.cwd(), pathValue)
}

function die(message: string): never {
  console.error(message)
  process.exit(1)
}

function readArg(flag: string): string | undefined {
  const index = process.argv.indexOf(flag)
  if (index === -1) return undefined
  return process.argv[index + 1]
}

async function run(command: string[], env: Record<string, string>): Promise<void> {
  const proc = Bun.spawn({
    cmd: command,
    cwd: resolve(import.meta.dir, ".."),
    env: {
      ...process.env,
      ...env,
    },
    stdout: "inherit",
    stderr: "inherit",
  })

  const exitCode = await proc.exited
  if (exitCode !== 0) {
    die(`Command failed (${exitCode}): ${command.join(" ")}`)
  }
}

if (process.argv.includes("--help")) {
  console.info(helpText)
  process.exit(0)
}

const distDirArg = readArg("--dist-dir")
const distDir = distDirArg ? resolveInputPath(distDirArg) : resolve(import.meta.dir, "../dist")
const authToken = readArg("--auth-token") ?? process.env["SENTRY_AUTH_TOKEN"]
const org = readArg("--org") ?? process.env["SENTRY_ORG"] ?? "usenoor"
const project = readArg("--project") ?? process.env["SENTRY_PROJECT"] ?? "inline-server"
const url = readArg("--url") ?? process.env["SENTRY_URL"] ?? "https://us.sentry.io"
const sourceCommit = readArg("--commit") ?? process.env["SOURCE_COMMIT"]?.trim() ?? process.env["GIT_COMMIT_SHA"]?.trim() ?? "N/A"
const dryRun = process.argv.includes("--dry-run")

if (!existsSync(distDir)) {
  die(`Build output not found at ${distDir}`)
}

if (!authToken && !dryRun) {
  die("Missing Sentry auth. Set SENTRY_AUTH_TOKEN before uploading server sourcemaps.")
}

const release = buildServerSentryRelease(version, sourceCommit)
const dist = buildServerSentryDist(sourceCommit)

const env = {
  SENTRY_AUTH_TOKEN: authToken ?? "",
  SENTRY_ORG: org,
  SENTRY_PROJECT: project,
  SENTRY_URL: url,
}

console.info(`Injecting Sentry Debug IDs into ${distDir}`)
const injectCommand = ["bunx", "@sentry/cli", "sourcemaps", "inject", distDir]
if (dryRun) {
  console.info(injectCommand.join(" "))
} else {
  await run(injectCommand, env)
}

const uploadCommand = ["bunx", "@sentry/cli", "sourcemaps", "upload", "--release", release]
if (dist) {
  uploadCommand.push("--dist", dist)
}
uploadCommand.push(distDir)

console.info(`Uploading sourcemaps to ${org}/${project} as ${release}${dist ? ` (${dist})` : ""}`)
if (dryRun) {
  console.info(uploadCommand.join(" "))
} else {
  await run(uploadCommand, env)
}
