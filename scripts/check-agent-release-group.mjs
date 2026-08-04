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
    rustConstant: "MIN_SETUP_PLUGIN_VERSION",
    validate(manifest) {
      if (manifest.openclaw?.install?.npmSpec !== "@inline-openclaw/inline") {
        throw new Error("OpenClaw package is missing its canonical external install contract")
      }
    },
  },
  {
    directory: "hermes-agent",
    rustConstant: "MIN_MACHINE_PLUGIN_VERSION",
    validate(manifest) {
      if (manifest.inlineHermes?.machineSetupProtocol !== 1) {
        throw new Error("Hermes package must advertise machineSetupProtocol 1")
      }
    },
  },
]

const rustSources = new Map([
  ["MIN_SETUP_PLUGIN_VERSION", readFileSync(path.join(root, "cli/src/agents/openclaw.rs"), "utf8")],
  ["MIN_MACHINE_PLUGIN_VERSION", readFileSync(path.join(root, "cli/src/agents/hermes.rs"), "utf8")],
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
