import assert from "node:assert/strict"
import { execFileSync } from "node:child_process"
import { createHash } from "node:crypto"
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises"
import { createServer } from "node:http"
import os from "node:os"
import path from "node:path"

const names = ["@inline-chat/realtime-sdk", "@inline-chat/protocol"]

export function assertAdmissionSource(manifest, candidate) {
  if (candidate) {
    assert.match(manifest.sourceSha, /^[a-f0-9]{40}$/i, "candidate mode requires a source SHA, never published-npm")
  } else {
    assert.equal(manifest.sourceSha, "published-npm", "source artifacts require explicit --candidate mode")
  }
}

// The real host CLI must resolve unpublished dependencies during its own npm
// install. Serve only these verified artifacts; every other package stays on
// its normal registry, and unknown @inline-chat packages fail closed.
export async function withCandidateRegistry(artifactDir, manifest, run) {
  assertAdmissionSource(manifest, true)
  const packages = new Map()
  for (const name of names) {
    const matches = manifest.packages.filter((item) => item.name === name)
    assert.equal(matches.length, 1, `expected one ${name} candidate`)
    const item = matches[0]
    assert.equal(path.basename(item.file), item.file, "candidate archive must be a basename")
    const bytes = await readFile(path.join(artifactDir, item.file))
    assert.equal(createHash("sha256").update(bytes).digest("hex"), item.sha256, `${name} candidate hash`)
    const pkg = JSON.parse(execFileSync("tar", ["-xOzf", "-", "package/package.json"], { input: bytes, encoding: "utf8" }))
    assert.equal(pkg.name, name, "candidate archive name")
    assert.equal(pkg.version, item.version, "candidate archive version")
    packages.set(name, { item, pkg, bytes })
  }
  const directory = await mkdtemp(path.join(os.tmpdir(), "inline-candidate-registry-"))
  const npmrc = path.join(directory, "npmrc")
  let url
  const server = createServer((request, response) => {
    if (request.method !== "GET" && request.method !== "HEAD") {
      response.writeHead(405).end()
      return
    }
    let pathname
    try { pathname = decodeURIComponent(new URL(request.url, url).pathname) } catch {
      response.writeHead(400).end()
      return
    }
    for (const [name, { item, pkg, bytes }] of packages) {
      const tarball = `/tarballs/${encodeURIComponent(item.file)}`
      if (pathname === `/tarballs/${item.file}`) {
        response.writeHead(200, { "content-type": "application/octet-stream", "content-length": bytes.length })
        response.end(request.method === "HEAD" ? undefined : bytes)
        return
      }
      if (pathname === `/${name}`) {
        const metadata = JSON.stringify({ name, "dist-tags": { latest: item.version }, versions: {
          [item.version]: { ...pkg, dist: { tarball: `${url}${tarball}`,
            integrity: `sha512-${createHash("sha512").update(bytes).digest("base64")}`,
            shasum: createHash("sha1").update(bytes).digest("hex") } },
        } })
        response.writeHead(200, { "content-type": "application/json" })
        response.end(request.method === "HEAD" ? undefined : metadata)
        return
      }
    }
    response.writeHead(404).end()
  })
  try {
    await new Promise((resolve, reject) => {
      server.once("error", reject)
      server.listen(0, "127.0.0.1", resolve)
    })
    url = `http://127.0.0.1:${server.address().port}`
    await writeFile(npmrc, `@inline-chat:registry=${url}/\n`, { mode: 0o600 })
    return await run({ env: { NPM_CONFIG_USERCONFIG: npmrc, npm_config_userconfig: npmrc }, url, npmrc })
  } finally {
    server.closeAllConnections()
    await new Promise((resolve) => server.close(resolve))
    await rm(directory, { recursive: true, force: true })
  }
}
