#!/usr/bin/env node

import { execFileSync } from "node:child_process"
import { readFileSync } from "node:fs"
import path from "node:path"
import { fileURLToPath } from "node:url"

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..")
const sourceOnly = process.argv.includes("--source-only")

const packages = [
  {
    directory: "openclaw",
    minimumRustConstant: "MINIMUM_SETUP_PLUGIN_VERSION",
    rustPackageSpecConstant: "SETUP_PLUGIN_SPEC",
    validate(manifest) {
      if (manifest.openclaw?.install?.npmSpec !== "@inline-openclaw/inline") {
        throw new Error("OpenClaw package is missing its canonical external install contract")
      }
    },
  },
  {
    directory: "hermes-agent",
    minimumRustConstant: "MINIMUM_HERMES_PLUGIN_VERSION",
    rustPackageSpecConstant: "HERMES_PLUGIN_PACKAGE_SPEC",
    validate(manifest) {
      if (manifest.inlineHermes?.machineSetupProtocol !== 1) {
        throw new Error("Hermes package must advertise machineSetupProtocol 1")
      }
      if (manifest.inlineHermes?.install?.npmSpec !== manifest.name) {
        throw new Error("Hermes package is missing its canonical external npm install contract")
      }
    },
  },
]

const rustSources = new Map([
  ["SETUP_PLUGIN_SPEC", readFileSync(path.join(root, "cli/src/agents/openclaw.rs"), "utf8")],
  ["HERMES_PLUGIN_PACKAGE_SPEC", readFileSync(path.join(root, "cli/src/agents/hermes.rs"), "utf8")],
])

function parseSemver(value) {
  const match = String(value).match(/^(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?(?:\+[0-9A-Za-z.-]+)?$/)
  if (!match) throw new Error(`Invalid semantic version: ${value}`)
  return {
    core: match.slice(1, 4).map(Number),
    prerelease: match[4]?.split(".") ?? [],
  }
}

function semverAtLeast(value, minimum) {
  const actual = parseSemver(value)
  const floor = parseSemver(minimum)
  for (let index = 0; index < actual.core.length; index += 1) {
    if (actual.core[index] !== floor.core[index]) return actual.core[index] > floor.core[index]
  }
  if (actual.prerelease.length === 0) return true
  if (floor.prerelease.length === 0) return false
  return value === minimum
}

for (const entry of packages) {
  const manifest = JSON.parse(
    readFileSync(path.join(root, entry.directory, "package.json"), "utf8"),
  )
  entry.validate(manifest)

  const source = rustSources.get(entry.rustPackageSpecConstant)
  const specMatch = source?.match(new RegExp(`const ${entry.rustPackageSpecConstant}: &str = "([^"]+)";`))
  const minimumMatch = source?.match(new RegExp(`const ${entry.minimumRustConstant}: &str = "([^"]+)";`))
  const npmSpec =
    entry.directory === "openclaw"
      ? manifest.openclaw.install.npmSpec
      : manifest.inlineHermes.install.npmSpec
  if (specMatch?.[1] !== npmSpec) {
    throw new Error(
      `${entry.rustPackageSpecConstant} must request latest external spec ${npmSpec}, found ${specMatch?.[1] ?? "missing"}`,
    )
  }
  const minimumVersion = minimumMatch?.[1]
  if (!minimumVersion) {
    throw new Error(`${entry.minimumRustConstant} is missing`)
  }
  parseSemver(minimumVersion)
  if (/include_(?:bytes|str)!\s*\([^)]*(?:openclaw|hermes-agent|plugin\/inline|adapter\.py|sidecar\/index\.mjs)/i.test(source)) {
    throw new Error("Inline CLI must install external agent packages and must not embed plugin payload files")
  }
  if (entry.directory === "openclaw") {
    if (!source.includes("--accept-capabilities")) {
      throw new Error("OpenClaw setup must explicitly accept trusted Inline capabilities")
    }
    const updater = readFileSync(path.join(root, "openclaw/src/inline/update-command.ts"), "utf8")
    if (!updater.includes("--accept-capabilities")) {
      throw new Error("OpenClaw chat updater must explicitly accept trusted Inline capabilities")
    }
  }

  if (!sourceOnly) {
    const publishedRelease = JSON.parse(
      execFileSync("npm", ["view", `${manifest.name}@${manifest.version}`, "--json"], {
        cwd: root,
        encoding: "utf8",
        stdio: ["ignore", "pipe", "pipe"],
      }),
    )
    if (publishedRelease.version !== manifest.version) {
      throw new Error(
        `${manifest.name}@${manifest.version} is not the published release contract`,
      )
    }
    entry.validate(publishedRelease)

    const publishedLatest = JSON.parse(
      execFileSync("npm", ["view", `${npmSpec}@latest`, "--json"], {
        cwd: root,
        encoding: "utf8",
        stdio: ["ignore", "pipe", "pipe"],
      }),
    )
    entry.validate(publishedLatest)
    if (!semverAtLeast(publishedLatest.version, minimumVersion)) {
      throw new Error(
        `${npmSpec}@latest is ${publishedLatest.version}, below CLI minimum ${minimumVersion}`,
      )
    }
  }

  console.log(
    `${manifest.name}@${manifest.version}: ${sourceOnly ? "source contract ready" : `${npmSpec}@latest install contract verified`}`,
  )
}
