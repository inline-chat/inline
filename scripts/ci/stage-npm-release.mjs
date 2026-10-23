import { execFileSync } from "node:child_process"
import { createHash } from "node:crypto"
import { appendFile, cp, lstat, mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises"
import os from "node:os"
import path from "node:path"
import { fileURLToPath, pathToFileURL } from "node:url"
import { PACKAGE_CONFIGS, canonicalSemver, parseReleaseTag } from "./release-tag.mjs"

const defaultRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..")
const omitted = new Set([
  ".git", ".npmrc", "node_modules", "dist", "build", "coverage",
  "bun.lock", "bun.lockb", "package-lock.json", "npm-shrinkwrap.json", "yarn.lock", "pnpm-lock.yaml",
])

export function parseStageArgs(argv) {
  const options = {}
  const flags = { "--package": "packageKey", "--version": "version", "--tag": "tag", "--sha": "sha", "--output-dir": "outputDir" }
  for (let index = 0; index < argv.length; index += 2) {
    const key = flags[argv[index]]
    const value = argv[index + 1]
    if (!key || !value || value.startsWith("--") || Object.hasOwn(options, key)) {
      throw new Error("Expected --package KEY --version VERSION --tag GIT_TAG --sha SHA --output-dir DIRECTORY")
    }
    options[key] = value
  }
  if (Object.keys(options).length !== Object.keys(flags).length) throw new Error("All release staging arguments are required")
  return options
}

function isolatedManifest(manifest, rootManifest) {
  const staged = structuredClone(manifest)
  // Root overrides and workspace resolution never enter this directory. A
  // package-local override would undermine the same registry dependency check.
  for (const field of ["overrides", "resolutions", "workspaces"]) {
    if (staged[field] != null) throw new Error(`Release package must not define ${field}`)
  }
  for (const [name, version] of Object.entries(staged.devDependencies ?? {})) {
    if (typeof version !== "string" || !version.startsWith("catalog:")) continue
    const catalog = version === "catalog:" ? rootManifest.catalog : rootManifest.catalogs?.[version.slice(8)]
    const resolved = catalog?.[name]
    if (typeof resolved !== "string" || resolved.startsWith("catalog:")) throw new Error(`Missing catalog version for ${name}`)
    staged.devDependencies[name] = resolved
  }
  for (const field of ["dependencies", "peerDependencies", "optionalDependencies", "devDependencies"]) {
    for (const [name, version] of Object.entries(staged[field] ?? {})) {
      if (typeof version !== "string" || /^(?:workspace|file|link|portal|catalog|patch):/.test(version)) {
        throw new Error(`${field}.${name} must resolve from the registry: ${version}`)
      }
    }
  }
  return staged
}

// The workflow checks that the committed version matches the tag before source
// checks. This isolated copy adds artifact identity and registry dependencies.
export async function stageNpmRelease(options, { repoRoot = defaultRoot } = {}) {
  const release = parseReleaseTag(options.tag, "npm")
  if (!Object.hasOwn(PACKAGE_CONFIGS, options.packageKey) || release.packageKey !== options.packageKey ||
      canonicalSemver(options.version) !== release.version || !/^[a-f0-9]{40}$/.test(options.sha)) {
    throw new Error("Release package, version, tag, and full commit SHA must agree")
  }
  if (options.packageKey === "hermes-agent") throw new Error("Hermes requires its existing release-stage.mjs helper")
  if (typeof options.outputDir !== "string" || !options.outputDir || /[\r\n]/.test(options.outputDir)) throw new Error("A release output directory is required")
  const config = PACKAGE_CONFIGS[options.packageKey]
  const packageRoot = path.join(repoRoot, config.directory)
  const manifest = JSON.parse(await readFile(path.join(packageRoot, "package.json"), "utf8"))
  if (manifest.name !== config.name || manifest.private === true) throw new Error("Source package must match the public package allowlist")
  const rootManifest = JSON.parse(await readFile(path.join(repoRoot, "package.json"), "utf8"))
  const staged = isolatedManifest(manifest, rootManifest)
  const temporary = await mkdtemp(path.join(os.tmpdir(), "inline-npm-release-"))
  const stage = path.join(temporary, "package")
  const outputDir = path.resolve(options.outputDir)
  const environment = { ...process.env }
  delete environment.NODE_PATH
  const command = (program, args, capture = false) => execFileSync(program, args, {
    cwd: stage, env: environment, encoding: "utf8", timeout: 600_000,
    stdio: capture ? ["ignore", "pipe", "inherit"] : ["ignore", "inherit", "inherit"],
  })
  try {
    await cp(packageRoot, stage, {
      recursive: true,
      filter: async (source) => {
        const parts = path.relative(packageRoot, source).split(path.sep)
        if (parts.some((part) => omitted.has(part) || part === ".env" || part.startsWith(".env.") || part.endsWith(".tsbuildinfo"))) return false
        if ((await lstat(source)).isSymbolicLink()) throw new Error("Release source must not link outside the staged package")
        return true
      },
    })
    await writeFile(path.join(stage, "package.json"), JSON.stringify(staged, null, 2) + "\n")
    command("npm", ["install", "--ignore-scripts", "--no-audit", "--no-fund", "--package-lock=false", "--registry=https://registry.npmjs.org"])

    staged.version = options.version
    staged.gitHead = options.sha
    staged.inlineRelease = { tag: options.tag, sha: options.sha }
    await writeFile(path.join(stage, "package.json"), JSON.stringify(staged, null, 2) + "\n")
    if (options.packageKey === "bot-client") {
      // Its workspace build also rebuilds ../bot-api-types. Here npm installed
      // that exact declared published dependency, so compile only this package.
      command("npm", ["exec", "--offline", "--ignore-scripts", "--", "tsc", "-p", "tsconfig.json"])
    } else {
      command("npm", ["run", "--ignore-scripts", "build"])
    }
    await mkdir(outputDir, { recursive: true })
    const packed = JSON.parse(command("npm", ["pack", "--ignore-scripts", "--json", "--pack-destination", outputDir], true))
    const item = packed[0]
    if (packed.length !== 1 || item?.name !== config.name || item.version !== options.version ||
        typeof item.filename !== "string" || path.basename(item.filename) !== item.filename || !item.filename.endsWith(".tgz")) {
      throw new Error("npm pack returned an unexpected release artifact")
    }
    const artifact = path.join(outputDir, item.filename)
    const bytes = await readFile(artifact)
    const integrity = `sha512-${createHash("sha512").update(bytes).digest("base64")}`
    if (item.integrity !== integrity) throw new Error("Packed artifact integrity does not match its bytes")
    const sha256 = createHash("sha256").update(bytes).digest("hex")
    const receipt = { name: config.name, version: options.version, tag: options.tag, sha: options.sha, file: item.filename, integrity, sha256 }
    await writeFile(path.join(outputDir, "release-artifact.json"), JSON.stringify(receipt, null, 2) + "\n")
    if (process.env.GITHUB_OUTPUT) await appendFile(process.env.GITHUB_OUTPUT, `artifact=${artifact}\nartifact-sha256=${sha256}\nintegrity=${integrity}\n`)
    console.log(`Staged ${config.name}@${options.version}: ${sha256}`)
    return receipt
  } finally {
    await rm(temporary, { recursive: true, force: true })
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  stageNpmRelease(parseStageArgs(process.argv.slice(2))).catch((error) => {
    console.error(`npm release staging failed: ${error instanceof Error ? error.message : String(error)}`)
    process.exitCode = 1
  })
}
