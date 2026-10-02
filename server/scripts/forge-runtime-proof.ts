import { createHash } from "node:crypto"
import { readFileSync, realpathSync } from "node:fs"
import { createRequire } from "node:module"
import { resolve } from "node:path"

// Exact, unmerged upstream security fix; package identity/version are unchanged
// from that commit. Replace the pin and these proofs when a fixed release ships.
export const FORGE_COMMIT = "ceba34402e329f0365134f23fe19898756527d65"
const FIXED_RSA_HASH = "acc22e5d36e27832c34e02dd3933aad7977d45b047eead5016520735efedc9c5"

export const createApnRequire = () => {
  const serverRequire = createRequire(resolve(import.meta.dir, "../package.json"))
  return createRequire(realpathSync(serverRequire.resolve("apn")))
}

export const verifyForgeSource = () => {
  const require = createApnRequire()
  const manifest = require("node-forge/package.json") as { name: string; version: string }
  const source = readFileSync(require.resolve("node-forge/lib/rsa.js"))
  const rsaHash = createHash("sha256").update(source).digest("hex")
  if (manifest.name !== "node-forge" || manifest.version !== "1.4.1-0" || rsaHash !== FIXED_RSA_HASH) {
    throw new Error("APNs must resolve the reviewed Forge security fix before bundling.")
  }
  return { package: manifest.name, version: manifest.version, commit: FORGE_COMMIT, rsaHash }
}

// The normal server build is unminified. Check the guard in its actual output,
// as production node_modules alone cannot attest a separately bundled server.
export const verifyForgeBundle = (source: string) => {
  if (!/obj\.value\[0\]\.value\.length\s*!==\s*\(["']parameters["']\s+in\s+capture\s*\?\s*2\s*:\s*1\)/.test(source)) {
    throw new Error("Bundled server is missing the reviewed Forge DigestAlgorithm guard.")
  }
}
