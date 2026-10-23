import { spawnSync } from "node:child_process"
import { createHash } from "node:crypto"
import { appendFile, lstat, mkdtemp, readFile, rm } from "node:fs/promises"
import os from "node:os"
import path from "node:path"
import { pathToFileURL } from "node:url"
import { PACKAGE_CONFIGS, canonicalSemver, parseReleaseTag } from "./release-tag.mjs"

class Blocked extends Error {}
const requireRelease = (condition, reason) => { if (!condition) throw new Blocked(reason) }
const digest = (bytes, algorithm, encoding) => createHash(algorithm).update(bytes).digest(encoding)
const record = (value) => value !== null && typeof value === "object" && !Array.isArray(value)

export function compareVersions(left, right) {
  const parts = (value) => { canonicalSemver(value); const [core, ...pre] = value.split("-"); return [core.split("."), pre.join("-").split(".")] }
  const [a, ap] = parts(left), [b, bp] = parts(right)
  const compare = (x, y) => x < y ? -1 : x > y ? 1 : 0
  for (let i = 0; i < 3; i++) { const order = compare(BigInt(a[i]), BigInt(b[i])); if (order) return order }
  if (!ap[0] || !bp[0]) return compare(Boolean(bp[0]), Boolean(ap[0]))
  for (let i = 0; i < Math.max(ap.length, bp.length); i++) {
    if (ap[i] === undefined || bp[i] === undefined) return compare(ap.length, bp.length)
    const numericA = /^\d+$/.test(ap[i]), numericB = /^\d+$/.test(bp[i])
    const order = numericA && numericB ? compare(BigInt(ap[i]), BigInt(bp[i]))
      : numericA !== numericB ? (numericA ? -1 : 1) : compare(ap[i], bp[i])
    if (order) return order
  }
  return 0
}

// Public, unauthenticated reads; only an actual 404 means absent. Tests inject
// both transport and a reserved registry origin, so they cannot call production.
/** @param {(url: string, init?: RequestInit) => Promise<Response>} transport */
export function createRegistry(transport = fetch, origin = "https://registry.npmjs.org") {
  const get = async (url, binary = false) => {
    const target = new URL(url)
    if (target.origin !== origin || target.username || target.password) throw new Error("Unexpected npm tarball origin")
    const response = await transport(target.href, { redirect: "error", signal: AbortSignal.timeout(10_000), headers: { "Cache-Control": "no-cache" } })
    if (response.status === 404) return null
    if (!response.ok) throw new Error(`npm registry returned HTTP ${response.status}`)
    return binary ? Buffer.from(await response.arrayBuffer()) : response.json()
  }
  return {
    version: (name, version) => get(`${origin}/${encodeURIComponent(name)}/${encodeURIComponent(version)}`),
    tags: async (name) => (await get(`${origin}/-/package/${encodeURIComponent(name)}/dist-tags`)) ?? {},
    tarball: (url) => get(url, true),
  }
}

function command(program, args, input, env = process.env, cwd) {
  const result = spawnSync(program, args, { input, env, cwd, encoding: "utf8", timeout: 120_000, maxBuffer: 20 * 1024 * 1024 })
  if (result.error) throw new Error(`${program} could not complete`)
  return { status: result.status, stdout: result.stdout }
}

export function createGitHub(repository = process.env.GITHUB_REPOSITORY ?? "inline-chat/inline", run = command) {
  if (!/^[\w.-]+\/[\w.-]+$/.test(repository)) throw new Error("Invalid GitHub repository")
  return async (method, endpoint, payload) => {
    const args = ["api", "--hostname", "github.com", "--include", "--method", method, `repos/${repository}/${endpoint}`]
    if (payload !== undefined) args.push("--input", "-")
    const response = run("gh", args, payload === undefined ? undefined : JSON.stringify(payload))
    const output = response.stdout.replace(/\r\n/g, "\n")
    const header = output.match(/^HTTP\/[\d.]+ (\d{3})[^\n]*\n(?:[^\n]+\n)*\n/)
    if (!header) throw new Error("GitHub did not return an HTTP response")
    const status = Number(header[1])
    if (method === "GET" && status === 404) return null
    if (response.status !== 0 || status < 200 || status >= 300) throw new Error(`GitHub returned HTTP ${status}`)
    return JSON.parse(output.slice(header[0].length))
  }
}

async function npmCommand(args) {
  // No .npmrc or long-lived token fallback. The fresh publisher needs only the
  // GitHub OIDC environment and npm's trusted-publisher authorization.
  const env = { ...process.env }
  for (const key of Object.keys(env)) if (/^npm_config_/i.test(key) || /^(?:npm_token|node_auth_token)$/i.test(key)) delete env[key]
  const cwd = await mkdtemp(path.join(os.tmpdir(), "inline-npm-publisher-"))
  try { return command("npm", [...args, `--userconfig=${path.join(cwd, "user.npmrc")}`, `--globalconfig=${path.join(cwd, "global.npmrc")}`, "--registry=https://registry.npmjs.org"], undefined, env, cwd) }
  finally { await rm(cwd, { recursive: true, force: true }) }
}

export async function publishNpmRelease(directory, {
  tag = process.env.RELEASE_TAG, sha = process.env.RELEASE_COMMIT,
  repository = process.env.GITHUB_REPOSITORY ?? "inline-chat/inline",
  registry = createRegistry(), github = createGitHub(repository), npm = npmCommand,
  pause = (ms) => new Promise((resolve) => setTimeout(resolve, ms)),
} = {}) {
  const release = parseReleaseTag(tag, "npm")
  requireRelease(/^[\w.-]+\/[\w.-]+$/.test(repository), "Invalid GitHub repository")
  requireRelease(/^[a-f0-9]{40}$/.test(sha ?? ""), "A full release commit SHA is required")
  const receiptPath = path.resolve(directory, "release-artifact.json")
  requireRelease((await lstat(receiptPath)).isFile(), "Release receipt must be a regular file")
  const receipt = JSON.parse(await readFile(receiptPath, "utf8"))
  requireRelease(record(receipt) && receipt.name === PACKAGE_CONFIGS[release.packageKey].name && receipt.version === release.version &&
    receipt.tag === tag && receipt.sha === sha, "Retained artifact identity differs from this release")
  requireRelease(typeof receipt.file === "string" && /^[\w.-]+\.tgz$/.test(receipt.file) && path.basename(receipt.file) === receipt.file,
    "Retained artifact must be a tarball basename")
  const artifact = path.resolve(directory, receipt.file)
  requireRelease((await lstat(artifact)).isFile(), "Retained tarball must be a regular file")
  const bytes = await readFile(artifact)
  const matches = (value) => Buffer.isBuffer(value) && digest(value, "sha256", "hex") === receipt.sha256 && `sha512-${digest(value, "sha512", "base64")}` === receipt.integrity
  requireRelease(matches(bytes), "Retained artifact digest mismatch")

  let ref = await github("GET", `git/ref/tags/${encodeURIComponent(tag)}`)
  for (let i = 0; ref?.object?.type === "tag" && i < 5; i++) ref = await github("GET", `git/tags/${ref.object.sha}`)
  requireRelease(ref?.object?.type === "commit" && ref.object.sha === sha, "GitHub release tag does not identify the release commit")
  const sameRelease = (value) => {
    requireRelease(record(value) && value.tag_name === tag && value.target_commitish === sha && value.prerelease === (release.channel !== "latest") && value.draft === false,
      "Existing GitHub release has a different tag, source, or prerelease identity")
  }
  const existingRelease = await github("GET", `releases/tags/${encodeURIComponent(tag)}`)
  if (existingRelease !== null) sameRelease(existingRelease)
  const channelVersion = async () => {
    const tags = await registry.tags(receipt.name)
    requireRelease(record(tags), "Registry returned malformed dist-tags")
    const value = tags[release.channel]
    if (value !== undefined) { requireRelease(typeof value === "string", "Registry returned a malformed channel version"); canonicalSemver(value) }
    return value
  }
  const verifyVersion = async () => {
    const version = await registry.version(receipt.name, release.version)
    if (version === null) return false
    requireRelease(record(version) && version.name === receipt.name && version.version === receipt.version && record(version.dist) &&
      version.dist.integrity === receipt.integrity && typeof version.dist.tarball === "string", "Published version metadata differs from the retained artifact")
    const downloaded = await registry.tarball(version.dist.tarball)
    if (downloaded === null) return false
    requireRelease(matches(downloaded), "Published tarball bytes differ from the retained artifact")
    return true
  }
  const converge = async (check) => {
    for (let attempt = 0; attempt < 30; attempt++) {
      if (await check()) return true
      if (attempt < 29) await pause(5_000)
    }
    return false
  }

  const existing = await registry.version(receipt.name, release.version)
  const current = await channelVersion()
  let changed = false
  if (existing === null) {
    requireRelease(!current || compareVersions(release.version, current) >= 0, `New release is older than the ${release.channel} channel (${current})`)
    // A response can be lost after npm accepted the upload. Verify the registry
    // before deciding it failed; never upload a second tarball on this run.
    let result
    try { result = await npm(["publish", artifact, "--ignore-scripts", "--access", "public", "--tag", release.channel]) } catch { result = { status: 1 } }
    if (!await converge(verifyVersion)) throw new Error(result.status === 0 ? "Published version did not converge in the registry" : "npm publish failed; retained version is still absent")
    changed = true
  } else if (!await converge(verifyVersion)) throw new Error("Existing published tarball is unavailable")

  let channel = await channelVersion()
  if (!channel || compareVersions(channel, release.version) < 0) {
    try { await npm(["dist-tag", "add", `${receipt.name}@${release.version}`, release.channel]) } catch { /* Verify a possibly accepted operation below. */ }
    if (!await converge(async () => { channel = await channelVersion(); return channel !== undefined && compareVersions(channel, release.version) >= 0 })) {
      throw new Error(`npm ${release.channel} channel did not converge`)
    }
    changed = true
  }

  const saved = await github("GET", `releases/tags/${encodeURIComponent(tag)}`)
  if (saved !== null) sameRelease(saved)
  else {
    const refs = await github("GET", `git/matching-refs/tags/${release.packageKey}-v`)
    requireRelease(Array.isArray(refs), "GitHub returned malformed release tags")
    const candidates = refs.flatMap((entry) => {
      try { const parsed = parseReleaseTag(entry.ref?.replace(/^refs\/tags\//, ""), "npm"); return parsed.packageKey === release.packageKey && compareVersions(parsed.version, release.version) < 0 ? [parsed] : [] } catch { return [] }
    }).sort((a, b) => compareVersions(b.version, a.version))
    let previous
    for (const candidate of candidates) {
      const prior = await github("GET", `releases/tags/${encodeURIComponent(candidate.tag)}`)
      if (record(prior) && prior.tag_name === candidate.tag && prior.draft === false) { previous = candidate; break }
    }
    const notes = await github("POST", "releases/generate-notes", { tag_name: tag, target_commitish: sha, ...(previous ? { previous_tag_name: previous.tag } : {}) })
    requireRelease(record(notes) && typeof notes.name === "string" && typeof notes.body === "string", "GitHub returned malformed automatic release notes")
    const body = previous ? notes.body : `Initial ${receipt.name} release tag. Source [${sha}](https://github.com/${repository}/commit/${sha}).\n\n${notes.body}`
    const payload = { tag_name: tag, target_commitish: sha, name: notes.name, body, prerelease: release.channel !== "latest", draft: false, make_latest: "false" }
    try { sameRelease(await github("POST", "releases", payload)) }
    catch (error) { const resumed = await github("GET", `releases/tags/${encodeURIComponent(tag)}`); if (resumed === null) throw error; sameRelease(resumed) }
    changed = true
  }
  return { outcome: changed ? "published" : "already-current", reason: `${receipt.name}@${release.version} verified; ${release.channel}=${channel ?? release.version}; GitHub notes complete` }
}

export async function runPublisher(argv, options = {}, output = process.env.GITHUB_OUTPUT) {
  let result
  try {
    requireRelease(argv.length === 1, "Usage: node publish-npm-release.mjs <artifact-dir>")
    result = await publishNpmRelease(argv[0], options)
  } catch (error) {
    result = { outcome: error instanceof Blocked ? "blocked" : "failed", reason: error instanceof Error ? error.message : "Unexpected publication failure" }
  }
  result.reason = result.reason.replace(/\p{Cc}/gu, " ").slice(0, 500)
  if (output) await appendFile(output, `outcome=${result.outcome}\nreason=${result.reason}\n`)
  console.log(`${result.outcome}: ${result.reason}`)
  return result
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  const result = await runPublisher(process.argv.slice(2))
  if (["blocked", "failed"].includes(result.outcome)) process.exitCode = 1
}
