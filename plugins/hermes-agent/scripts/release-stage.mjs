import { appendFile, chmod, cp, mkdir, mkdtemp, readFile, writeFile } from "node:fs/promises"
import { createHash } from "node:crypto"
import os from "node:os"
import path from "node:path"
import { execFileSync } from "node:child_process"
import { fileURLToPath } from "node:url"
import { parseReleaseTag } from "../../../scripts/ci/release-tag.mjs"

const packageRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..")
const repoRoot = path.resolve(packageRoot, "..", "..")
const { mode, outputDir: requestedOutputDir, candidateSdkTarball, candidateProtocolTarball, verifySourceBundle, version, tag, sha } = parseArgs(process.argv.slice(2))
if (verifySourceBundle && (candidateSdkTarball || candidateProtocolTarball)) {
  throw new Error("--verify-source-bundle requires registry dependencies; candidate tarball overrides are not allowed")
}
const sourceBundle = path.join(packageRoot, "plugin", "inline", "sidecar", "index.mjs")
if (verifySourceBundle) {
  execFileSync("git", ["ls-files", "--error-unmatch", "--", path.relative(repoRoot, sourceBundle)], {
    cwd: repoRoot,
    stdio: "ignore",
  })
}
const stageRoot = await mkdtemp(path.join(os.tmpdir(), "inline-hermes-release-"))
const stagePackageRoot = path.join(stageRoot, "plugins", "hermes-agent")
const outputDir = requestedOutputDir == null
  ? path.join(stageRoot, "artifact")
  : path.resolve(requestedOutputDir)
const packageJson = JSON.parse(await readFile(path.join(packageRoot, "package.json"), "utf8"))
if (version && (packageJson.name !== parseReleaseTag(tag, "npm").name || packageJson.private === true)) {
  throw new Error("Expected the public Hermes release package")
}
const prereleaseTag = String(version ?? packageJson.version ?? "").split("-", 2)[1]?.split(".", 1)[0]

const stageEntries = [
  "LICENSE",
  "README.md",
  "RELEASE.md",
  "package.json",
  "plugin",
  "scripts",
  "src",
  "tests",
  "tsconfig.json",
  "vitest.config.ts",
]

await mkdir(stagePackageRoot, { recursive: true })
await mkdir(outputDir, { recursive: true })
for (const entry of stageEntries) {
  await cp(path.join(packageRoot, entry), path.join(stagePackageRoot, entry), {
    recursive: true,
    filter(source) {
      const relative = path.relative(packageRoot, source)
      const parts = relative.split(path.sep)
      if (parts.some((part) => part === ".env" || part.startsWith(".env."))) {
        return false
      }
      return relative !== path.join("plugin", "inline", "sidecar", "index.mjs")
    },
  })
}
await cp(path.join(repoRoot, ".oxlintignore"), path.join(stageRoot, ".oxlintignore"))

if (candidateSdkTarball || candidateProtocolTarball) {
  if (!candidateSdkTarball || !candidateProtocolTarball) {
    throw new Error("candidate staging requires both SDK and protocol tarballs")
  }
  await writeFile(path.join(stagePackageRoot, "package.json"), JSON.stringify({
    ...packageJson,
    dependencies: {
      ...packageJson.dependencies,
      "@inline-chat/realtime-sdk": `file:${path.resolve(candidateSdkTarball)}`,
      "@inline-chat/protocol": `file:${path.resolve(candidateProtocolTarball)}`,
    },
  }, null, 2))
}
execFileSync("npm", ["install", "--ignore-scripts", "--no-audit", "--no-fund"], {
  cwd: stagePackageRoot,
  stdio: "inherit",
})
if (candidateSdkTarball || candidateProtocolTarball) {
  // Restore publishable registry specs before checking and packing. Only the
  // disposable install graph uses local files from this source SHA.
  await writeFile(path.join(stagePackageRoot, "package.json"), JSON.stringify(packageJson, null, 2) + "\n")
  const installedSdk = JSON.parse(await readFile(path.join(stagePackageRoot, "node_modules", "@inline-chat", "realtime-sdk", "package.json"), "utf8"))
  const installedProtocol = JSON.parse(await readFile(path.join(stagePackageRoot, "node_modules", "@inline-chat", "protocol", "package.json"), "utf8"))
  if (installedSdk.version !== packageJson.dependencies["@inline-chat/realtime-sdk"] ||
      installedProtocol.version !== JSON.parse(await readFile(path.join(repoRoot, "packages", "protocol", "package.json"), "utf8")).version) {
    throw new Error("candidate dependency versions do not match the release manifest")
  }
}
execFileSync("bun", ["run", "check"], {
  cwd: stagePackageRoot,
  stdio: "inherit",
})

if (verifySourceBundle) {
  const builtBundle = await readFile(path.join(stagePackageRoot, "plugin", "inline", "sidecar", "index.mjs"))
  if (!builtBundle.equals(await readFile(sourceBundle))) {
    throw new Error("Hermes source sidecar differs from the isolated registry-dependency build; regenerate the tracked source bundle from release staging")
  }
  console.log(`Hermes source bundle verified: sha256:${createHash("sha256").update(builtBundle).digest("hex")}`)
}

if (version) {
  // Source contracts and the tracked bundle comparison must see the original
  // versions. Only this disposable, checked copy carries the release identity.
  await writeFile(path.join(stagePackageRoot, "package.json"), JSON.stringify({
    ...packageJson, version, gitHead: sha, inlineRelease: { tag, sha },
  }, null, 2) + "\n")
  const pluginPath = path.join(stagePackageRoot, "plugin", "inline", "plugin.yaml")
  const plugin = await readFile(pluginPath, "utf8")
  if (plugin.match(/^version:[^\r\n]*$/gm)?.length !== 1) throw new Error("Expected one Hermes plugin version")
  await writeFile(pluginPath, plugin.replace(/^version:[^\r\n]*$/m, `version: ${version}`))
  const cliPath = path.join(stagePackageRoot, "plugin", "inline", "cli.py")
  const cli = await readFile(cliPath, "utf8")
  const probeVersion = /^_PROBE_USER_AGENT = (["'])inline-hermes-agent-adapter\/[^"'\r\n]+\1$/gm
  if (cli.match(probeVersion)?.length !== 1) throw new Error("Expected one Hermes probe version")
  await writeFile(cliPath, cli.replace(probeVersion, `_PROBE_USER_AGENT = "inline-hermes-agent-adapter/${version}"`))
  execFileSync("bun", ["run", "build"], { cwd: stagePackageRoot, stdio: "inherit" })
}

const packedEntries = JSON.parse(execFileSync("npm", [
  "pack",
  "--ignore-scripts",
  "--json",
  "--silent",
  "--pack-destination",
  outputDir,
], {
  cwd: stagePackageRoot,
  encoding: "utf8",
  stdio: ["ignore", "pipe", "pipe"],
}))
const packed = packedEntries[0]
if (!packed?.filename || !Array.isArray(packed.files)) {
  throw new Error("npm pack did not return one artifact manifest")
}
if (version && (packedEntries.length !== 1 || packed.name !== packageJson.name || packed.version !== version ||
    path.basename(packed.filename) !== packed.filename || !packed.filename.endsWith(".tgz"))) {
  throw new Error("npm pack returned an unexpected Hermes release artifact")
}
const artifactPath = path.join(outputDir, packed.filename)
const artifactBytes = await readFile(artifactPath)
const artifactSha256 = createHash("sha256").update(artifactBytes).digest("hex")
if (version) {
  const integrity = `sha512-${createHash("sha512").update(artifactBytes).digest("base64")}`
  if (packed.integrity !== integrity) throw new Error("Packed artifact integrity does not match its bytes")
  const receipt = { name: packageJson.name, version, tag, sha, file: packed.filename, integrity, sha256: artifactSha256 }
  await writeFile(path.join(outputDir, "release-artifact.json"), JSON.stringify(receipt, null, 2) + "\n")
  if (process.env.GITHUB_OUTPUT) await appendFile(process.env.GITHUB_OUTPUT, `artifact=${artifactPath}\nartifact-sha256=${artifactSha256}\nintegrity=${integrity}\n`)
}
await chmod(artifactPath, 0o444)

if (mode === "--dry-run") {
  const publishArgs = ["publish", "--dry-run", "--ignore-scripts", "--access", "public", artifactPath]
  if (prereleaseTag) publishArgs.push("--tag", prereleaseTag)
  execFileSync("npm", publishArgs, {
    cwd: outputDir,
    stdio: "inherit",
  })
}

console.log(`Hermes release stage: ${stagePackageRoot}`)
console.log(`Hermes release artifact: ${artifactPath}`)
console.log(`Hermes release artifact sha256: ${artifactSha256}`)
console.log(`Hermes release artifact files: ${packed.files.map((file) => file.path).sort().join(",")}`)

function parseArgs(argv) {
  let mode = "--dry-run"
  let outputDir
  let candidateSdkTarball
  let candidateProtocolTarball
  let verifySourceBundle = false
  const release = {}
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index]
    if (arg === "--version" || arg === "--tag" || arg === "--sha") {
      const value = argv[++index]
      const key = arg.slice(2)
      if (!value || value.startsWith("--") || Object.hasOwn(release, key)) throw new Error(`${arg} requires one value`)
      release[key] = value
      continue
    }
    if (arg === "--dry-run" || arg === "--prepare-only") {
      mode = arg
      continue
    }
    if (arg === "--verify-source-bundle") {
      verifySourceBundle = true
      continue
    }
    if (arg === "--output-dir") {
      const value = argv[++index]
      if (!value || value.startsWith("--")) throw new Error("--output-dir requires a path")
      outputDir = value
      continue
    }
    if (arg === "--candidate-sdk-tarball" || arg === "--candidate-protocol-tarball") {
      const value = argv[++index]
      if (!value || value.startsWith("--")) throw new Error(`${arg} requires a path`)
      if (arg === "--candidate-sdk-tarball") candidateSdkTarball = value
      else candidateProtocolTarball = value
      continue
    }
    throw new Error(`unknown argument: ${arg}`)
  }
  if (Object.keys(release).length) {
    if (Object.keys(release).length !== 3) throw new Error("--version, --tag, and --sha are required together")
    const parsed = parseReleaseTag(release.tag, "npm")
    if (parsed.packageKey !== "hermes-agent" || parsed.version !== release.version || !/^[a-f0-9]{40}$/.test(release.sha)) {
      throw new Error("Hermes release version, tag, and full commit SHA must agree")
    }
    if (outputDir && /[\r\n]/.test(outputDir)) throw new Error("Invalid release output directory")
  }
  return { mode, outputDir, candidateSdkTarball, candidateProtocolTarball, verifySourceBundle, ...release }
}
