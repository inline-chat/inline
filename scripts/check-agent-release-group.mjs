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
    rustConstant: "SETUP_PLUGIN_VERSION",
    rustPackageSpecConstant: "SETUP_PLUGIN_SPEC",
    validate(manifest) {
      if (manifest.openclaw?.install?.npmSpec !== "@inline-openclaw/inline") {
        throw new Error("OpenClaw package is missing its canonical external install contract")
      }
    },
  },
  {
    directory: "hermes-agent",
    rustConstant: "HERMES_PLUGIN_VERSION",
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
  ["SETUP_PLUGIN_VERSION", readFileSync(path.join(root, "cli/src/agents/openclaw.rs"), "utf8")],
  ["HERMES_PLUGIN_VERSION", readFileSync(path.join(root, "cli/src/agents/hermes.rs"), "utf8")],
])

for (const entry of packages) {
  const manifest = JSON.parse(
    readFileSync(path.join(root, entry.directory, "package.json"), "utf8"),
  )
  entry.validate(manifest)

  const source = rustSources.get(entry.rustConstant)
  const match = source?.match(new RegExp(`const ${entry.rustConstant}: &str = "([^"]+)";`))
  if (match?.[1] !== manifest.version) {
    throw new Error(
      `${entry.rustConstant} must match ${manifest.name}@${manifest.version}, found ${match?.[1] ?? "missing"}`,
    )
  }

  if (entry.rustPackageSpecConstant) {
    const specMatch = source?.match(new RegExp(`const ${entry.rustPackageSpecConstant}: &str = "([^"]+)";`))
    const npmSpec =
      entry.directory === "openclaw"
        ? manifest.openclaw.install.npmSpec
        : manifest.inlineHermes.install.npmSpec
    const expectedSpec = `${npmSpec}@${manifest.version}`
    if (specMatch?.[1] !== expectedSpec) {
      throw new Error(
        `${entry.rustPackageSpecConstant} must be exact external spec ${expectedSpec}, found ${specMatch?.[1] ?? "missing"}`,
      )
    }
    if (/include_(?:bytes|str)!\s*\([^)]*(?:openclaw|hermes-agent|plugin\/inline|adapter\.py|sidecar\/index\.mjs)/i.test(source)) {
      throw new Error("Inline CLI must install external agent packages and must not embed plugin payload files")
    }
  }

  if (!sourceOnly) {
    const published = JSON.parse(
      execFileSync("npm", ["view", `${manifest.name}@latest`, "--json"], {
        cwd: root,
        encoding: "utf8",
        stdio: ["ignore", "pipe", "pipe"],
      }),
    )
    if (published.version !== manifest.version) {
      throw new Error(
        `${manifest.name}@latest is ${published.version}, but the CLI requires ${manifest.version}`,
      )
    }
    entry.validate(published)
  }

  console.log(
    `${manifest.name}@${manifest.version}: ${sourceOnly ? "source contract ready" : "published contract verified"}`,
  )
}
