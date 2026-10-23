#!/usr/bin/env node
import { execFileSync } from "node:child_process"
import { readFileSync } from "node:fs"
import path from "node:path"
import { pathToFileURL } from "node:url"
import { canonicalSemver, PACKAGE_CONFIGS, parseReleaseTag } from "./release-tag.mjs"

export function validateSourceManifest(manifest, release) {
  if (manifest.name !== release.name || manifest.private === true ||
      manifest.repository?.url !== "git+https://github.com/inline-chat/inline.git" ||
      manifest.repository?.directory !== release.directory || manifest.publishConfig?.access !== "public") {
    throw new Error("Package identity, public access or repository metadata does not match the release tag")
  }
  canonicalSemver(manifest.version)
}

const view = (name, requirement) => {
  try {
    return JSON.parse(execFileSync("npm", ["view", `${name}@${requirement}`, "version", "--json", "--registry", "https://registry.npmjs.org"], {
      encoding: "utf8", stdio: ["ignore", "pipe", "pipe"],
    }))
  } catch (error) {
    const failure = `${error.stdout || ""}\n${error.stderr || ""}`
    if (/\bE404\b/.test(failure)) return null
    throw new Error(`Could not verify published dependency ${name}@${requirement}; registry access failed`)
  }
}

export function checkInternalDependencies(manifest, registryView = view) {
  const publicNames = new Set(Object.values(PACKAGE_CONFIGS).map((config) => config.name))
  const dependencies = [manifest.dependencies, manifest.optionalDependencies, manifest.peerDependencies]
    .flatMap((group) => Object.entries(group || {}))
  for (const [name, requirement] of dependencies) {
    if (!name.startsWith("@inline-chat/") && !name.startsWith("@inline-openclaw/")) continue
    if (!publicNames.has(name) || typeof requirement !== "string" || /^(workspace:|file:|link:|npm:|https?:|git)/.test(requirement)) {
      throw new Error(`Internal dependency ${name}@${requirement} must use an explicit public registry requirement`)
    }
    const versions = registryView(name, requirement)
    if (!versions || (Array.isArray(versions) && versions.length === 0)) {
      throw new Error(`Publish internal dependency ${name}@${requirement} first; release requirements are not rewritten`)
    }
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const release = parseReleaseTag(process.env.RELEASE_TAG, "npm")
  const manifest = JSON.parse(readFileSync(path.join(release.directory, "package.json"), "utf8"))
  validateSourceManifest(manifest, release)
  checkInternalDependencies(manifest)
  console.log(`Validated ${release.name}@${release.version}; committed dependency requirements are published`)
}
