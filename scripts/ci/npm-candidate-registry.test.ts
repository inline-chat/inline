import { describe, expect, it } from "bun:test"
import { execFile, execFileSync } from "node:child_process"
import { createHash, randomUUID } from "node:crypto"
import { access, mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises"
import { createServer } from "node:http"
import os from "node:os"
import path from "node:path"
import { promisify } from "node:util"
import { assertAdmissionSource, withCandidateRegistry } from "./npm-candidate-registry.mjs"

const exec = promisify(execFile)
type Artifact = { name: string; version: string; file: string; sha256: string }
type Registry = { env: Record<string, string>; url: string; npmrc: string }

async function fixture(directory: string, name: string, version: string, dependencies = {}) {
  const file = `${name.replaceAll(/[@/]/g, "-")}-${version}.tgz`
  const source = path.join(directory, file + "-source")
  await mkdir(path.join(source, "package"), { recursive: true })
  const pkg = { name, version, main: "index.js", dependencies,
    scripts: { install: "node -e \"require('fs').writeFileSync('script-ran', 'bad')\"" } }
  const index = `module.exports = ${JSON.stringify(`${name}: ${randomUUID()} 🦜`)}\n`
  await writeFile(path.join(source, "package/package.json"), JSON.stringify(pkg))
  await writeFile(path.join(source, "package/index.js"), index)
  execFileSync("tar", ["-czf", path.join(directory, file), "-C", source, "package"])
  const bytes = await readFile(path.join(directory, file))
  const receipt: Artifact = { name, version, file, sha256: createHash("sha256").update(bytes).digest("hex") }
  return { receipt, pkg, bytes, index }
}

describe("OpenClaw candidate npm admission", () => {
  it("the real npm resolver installs original unpublished bytes with scope isolation and no lifecycle scripts", async () => {
    const directory = await mkdtemp(path.join(os.tmpdir(), "inline-npm-candidate-test-"))
    const version = `999.0.0-ci.${Date.now()}`
    const protocol = await fixture(directory, "@inline-chat/protocol", version)
    const sdk = await fixture(directory, "@inline-chat/realtime-sdk", version, { "@inline-chat/protocol": version })
    const other = await fixture(directory, `inline-unscoped-fixture-${randomUUID()}`, "1.0.0")
    const manifest = { sourceSha: "a".repeat(40), packages: [sdk.receipt, protocol.receipt] }
    const requests: string[] = []
    let defaultURL = ""
    const server = createServer((request, response) => {
      requests.push(request.url!)
      if (request.url === `/${other.pkg.name}`) {
        response.setHeader("content-type", "application/json")
        response.end(JSON.stringify({ name: other.pkg.name, "dist-tags": { latest: "1.0.0" }, versions: {
          "1.0.0": { ...other.pkg, dist: { tarball: `${defaultURL}/other.tgz`,
            integrity: `sha512-${createHash("sha512").update(other.bytes).digest("base64")}` } },
        } }))
      } else if (request.url === "/other.tgz") {
        response.end(other.bytes)
      } else {
        response.writeHead(404).end()
      }
    })
    let registry: Registry | undefined
    try {
      await new Promise<void>(resolve => server.listen(0, "127.0.0.1", resolve))
      defaultURL = `http://127.0.0.1:${(server.address() as { port: number }).port}`
      const consumer = path.join(directory, "consumer")
      await mkdir(consumer)
      await writeFile(path.join(consumer, "package.json"), JSON.stringify({ private: true, dependencies: { [sdk.pkg.name]: version } }))
      const userconfig = path.join(directory, "original-npmrc")
      await writeFile(userconfig, "# original config stays unchanged\n")
      const install = (env: Record<string, string>) => exec("npm", ["install", "--ignore-scripts", "--no-audit", "--no-fund", "--registry", defaultURL], {
        cwd: consumer, timeout: 30_000, env: { ...process.env, NPM_CONFIG_USERCONFIG: userconfig, npm_config_userconfig: userconfig,
          NPM_CONFIG_CACHE: path.join(directory, "cache"), ...env },
      })
      // The regression: a normal host install cannot resolve the unpublished SDK.
      await expect(install({})).rejects.toThrow()
      expect(requests.some(url => decodeURIComponent(url).includes(sdk.pkg.name))).toBe(true)
      requests.length = 0
      await writeFile(path.join(consumer, "package.json"), JSON.stringify({ private: true, dependencies: {
        [sdk.pkg.name]: version, [other.pkg.name]: other.pkg.version,
      } }))
      await withCandidateRegistry(directory, manifest, async (configuration: Registry) => {
        registry = configuration
        expect(await readFile(configuration.npmrc, "utf8")).toBe(`@inline-chat:registry=${configuration.url}/\n`)
        await install(configuration.env)
        for (const item of [sdk, protocol]) {
          const metadata = await (await fetch(`${configuration.url}/${encodeURIComponent(item.pkg.name)}`)).json() as any
          const downloaded = Buffer.from(await (await fetch(metadata.versions[version].dist.tarball)).arrayBuffer())
          expect(downloaded).toEqual(item.bytes)
          expect(await readFile(path.join(consumer, "node_modules", item.pkg.name, "index.js"), "utf8")).toBe(item.index)
          await expect(access(path.join(consumer, "node_modules", item.pkg.name, "script-ran"))).rejects.toThrow()
          expect(await readFile(path.join(directory, item.receipt.file))).toEqual(item.bytes)
        }
        expect((await fetch(`${configuration.url}/@inline-chat%2funknown`)).status).toBe(404)
        expect((await fetch(`${configuration.url}/${other.pkg.name}`)).status).toBe(404)
      })
      expect(requests.some(url => decodeURIComponent(url).includes("@inline-chat"))).toBe(false)
      expect(requests).toContain(`/${other.pkg.name}`)
      expect(requests).toContain("/other.tgz")
      expect(await readFile(userconfig, "utf8")).toBe("# original config stays unchanged\n")
      await expect(access(registry!.npmrc)).rejects.toThrow()
      await expect(fetch(registry!.url)).rejects.toThrow()
    } finally {
      server.closeAllConnections()
      await new Promise<void>(resolve => server.close(() => resolve()))
      await rm(directory, { recursive: true, force: true })
    }
  }, 60_000)

  it("rejects altered bytes or archive identities and cleans up after a failed CLI", async () => {
    const directory = await mkdtemp(path.join(os.tmpdir(), "inline-npm-candidate-invalid-"))
    try {
      const sdk = await fixture(directory, "@inline-chat/realtime-sdk", "999.0.0-ci.1")
      const protocol = await fixture(directory, "@inline-chat/protocol", "999.0.0-ci.1")
      const manifest = { sourceSha: "b".repeat(40), packages: [sdk.receipt, protocol.receipt] }
      await expect(withCandidateRegistry(directory, { ...manifest, packages: [
        { ...sdk.receipt, sha256: "0".repeat(64) }, protocol.receipt,
      ] }, () => { throw new Error("must not reach CLI") })).rejects.toThrow("candidate hash")
      await expect(withCandidateRegistry(directory, { ...manifest, packages: [
        { ...sdk.receipt, version: "999.0.0-ci.2" }, protocol.receipt,
      ] }, () => { throw new Error("must not reach CLI") })).rejects.toThrow("candidate archive version")
      let registry: Registry | undefined
      await expect(withCandidateRegistry(directory, manifest, async (configuration: Registry) => {
        registry = configuration
        throw new Error("CLI failed")
      })).rejects.toThrow("CLI failed")
      await expect(access(registry!.npmrc)).rejects.toThrow()
      await expect(fetch(registry!.url)).rejects.toThrow()
    } finally {
      await rm(directory, { recursive: true, force: true })
    }
  })

  it("requires candidate opt-in only in the source lane; published lanes remain registry-only", async () => {
    expect(() => assertAdmissionSource({ sourceSha: "published-npm" }, true)).toThrow()
    expect(() => assertAdmissionSource({ sourceSha: "a".repeat(40) }, false)).toThrow()
    assertAdmissionSource({ sourceSha: "published-npm" }, false)
    assertAdmissionSource({ sourceSha: "a".repeat(40) }, true)
    for (const name of ["integrations.yml", "openclaw-compatibility.yml"]) {
      const source = await readFile(path.resolve(import.meta.dir, "../../.github/workflows", name), "utf8")
      const calls = source.split("\n").filter(line => line.includes("node scripts/ci/check-openclaw-admission.mjs"))
      for (const call of calls) {
        expect(call.includes("--candidate")).toBe(call.includes('"$RUNNER_TEMP/inline-packages"'))
      }
    }
  })
})
