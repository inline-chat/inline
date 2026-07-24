import { chmod, cp, mkdir, mkdtemp, readFile, realpath, rm, lstat, writeFile } from "node:fs/promises"
import { spawnSync } from "node:child_process"
import os from "node:os"
import path from "node:path"
import { fileURLToPath } from "node:url"
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"
import { describeHealthFailure, main } from "../src/install.js"

const dirs: string[] = []
const packageRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..")
const envBefore = new Map<string, string | undefined>()
const nodeBin = spawnSync("which", ["node"], { encoding: "utf8" }).stdout.trim() || "node"

async function tempDir() {
  const dir = await mkdtemp(path.join(os.tmpdir(), "inline-hermes-test-"))
  dirs.push(dir)
  return dir
}

afterEach(async () => {
  vi.restoreAllMocks()
  restoreEnv()
  await Promise.all(dirs.splice(0).map((dir) => rm(dir, { recursive: true, force: true })))
})

describe("inline-hermes installer", () => {
  beforeEach(() => {
    setEnv("INLINE_NODE_BIN", nodeBin)
  })

  it("prints help from command or flag form", async () => {
    const log = vi.spyOn(console, "log").mockImplementation(() => {})

    await expect(main(["help"])).resolves.toBe(0)
    await expect(main(["--help"])).resolves.toBe(0)

    const text = log.mock.calls.map((call) => String(call[0])).join("\n")
    expect(text).toContain("inline-hermes install")
    expect(text).toContain("inline-hermes doctor")
    expect(text).toContain("[--hermes-home <path>] [--json]")
    expect(text).toContain("inline-hermes test-send")
    expect(text).toContain("inline-hermes install --force")
    expect(text).toContain("inline-hermes version")
  })

  it("prints the package version from command or flag form", async () => {
    const log = vi.spyOn(console, "log").mockImplementation(() => {})

    await expect(main(["version"])).resolves.toBe(0)
    await expect(main(["--version"])).resolves.toBe(0)
    await expect(main(["-v"])).resolves.toBe(0)

    const versions = log.mock.calls.map((call) => String(call[0]))
    expect(versions).toEqual([
      "@inline-chat/hermes-agent-adapter@0.0.5-alpha.0",
      "@inline-chat/hermes-agent-adapter@0.0.5-alpha.0",
      "@inline-chat/hermes-agent-adapter@0.0.5-alpha.0",
    ])
  })

  it("rejects malformed numeric flags and Inline targets", async () => {
    const home = await tempDir()
    const log = vi.spyOn(console, "log").mockImplementation(() => {})

    await expect(main(["test-send", "--hermes-home", home, "--to", "chat:123:extra", "--dry-run", "--json"]))
      .resolves.toBe(1)
    const payload = JSON.parse(String(log.mock.calls.at(-1)?.[0]))
    expect(payload.issues).toContain("invalid Inline target: chat:123:extra")

    await expect(main(["test-send", "--hermes-home", home, "--to", "chat:123", "--timeout-ms", "1000ms", "--dry-run", "--json"]))
      .rejects.toThrow("--timeout-ms requires a positive integer")
  })

  it("reports dry-run status without writing plugin files", async () => {
    const home = await tempDir()
    const log = vi.spyOn(console, "log").mockImplementation(() => {})

    const code = await main(["install", "--hermes-home", home, "--dry-run"])

    expect(code).toBe(0)
    expect(log).toHaveBeenCalled()
    await expect(readFile(path.join(home, "plugins", "inline", "plugin.yaml"), "utf8")).rejects.toThrow()
  })

  it("copies the plugin into the Hermes user plugin directory", async () => {
    const home = await tempDir()

    const code = await main(["install", "--hermes-home", home, "--force"])

    expect(code).toBe(0)
    const installed = path.join(home, "plugins", "inline")
    await expect(readFile(path.join(installed, "plugin.yaml"), "utf8")).resolves.toContain("name: inline-platform")
    await expect(readFile(path.join(installed, "adapter.py"), "utf8")).resolves.toContain("class InlineAdapter")
    await expect(readFile(path.join(installed, "sidecar", "index.mjs"), "utf8")).resolves.toContain("inline-sidecar")
  })

  it("routes new installs into the guided Hermes setup", async () => {
    const home = await tempDir()
    const log = vi.spyOn(console, "log").mockImplementation(() => {})

    const code = await main(["install", "--hermes-home", home, "--force"])

    expect(code).toBe(0)
    const text = log.mock.calls.map((call) => String(call[0])).join("\n")
    expect(text).toContain("hermes plugins enable inline-platform")
    expect(text).toContain("hermes gateway setup")
    expect(text).toContain("select Inline")
    expect(text).not.toContain("platforms.inline.token")
  })

  it("can symlink the plugin for local development", async () => {
    const home = await tempDir()

    const code = await main(["install", "--hermes-home", home, "--link", "--force"])

    expect(code).toBe(0)
    const stat = await lstat(path.join(home, "plugins", "inline"))
    expect(stat.isSymbolicLink()).toBe(true)
  })

  it("runs the built installer from an installed package layout", async () => {
    const dir = await tempDir()
    const pkgDir = path.join(dir, "pkg")
    const home = path.join(dir, "hermes")
    await mkdir(path.join(pkgDir, "dist"), { recursive: true })
    await mkdir(path.join(pkgDir, "plugin"), { recursive: true })

    const built = spawnSync("bun", [
      "build",
      "./src/install.ts",
      "--outdir",
      path.join(pkgDir, "dist"),
      "--entry-naming",
      "install.js",
      "--target=node",
      "--format=esm",
      "--packages=bundle",
    ], { cwd: packageRoot, encoding: "utf8" })
    expect(built.status, built.stderr || built.stdout).toBe(0)

    await cp(path.join(packageRoot, "package.json"), path.join(pkgDir, "package.json"))
    await cp(path.join(packageRoot, "plugin", "inline"), path.join(pkgDir, "plugin", "inline"), { recursive: true })

    const result = spawnSync(nodeBin, [
      path.join(pkgDir, "dist", "install.js"),
      "install",
      "--hermes-home",
      home,
      "--dry-run",
      "--json",
    ], {
      encoding: "utf8",
      env: { ...process.env, INLINE_NODE_BIN: nodeBin },
    })

    expect(result.status, result.stderr || result.stdout).toBe(0)
    const payload = JSON.parse(result.stdout) as { ok?: boolean; source?: string; sourceValid?: boolean }
    expect(payload.ok).toBe(true)
    expect(payload.sourceValid).toBe(true)
    expect(await realpath(payload.source || "")).toBe(await realpath(path.join(pkgDir, "plugin", "inline")))
  })

  it("copies only runtime plugin files from an installed package layout", async () => {
    const dir = await tempDir()
    const pkgDir = path.join(dir, "pkg")
    const home = path.join(dir, "hermes")
    await mkdir(path.join(pkgDir, "dist"), { recursive: true })
    await mkdir(path.join(pkgDir, "plugin"), { recursive: true })

    const built = spawnSync("bun", [
      "build",
      "./src/install.ts",
      "--outdir",
      path.join(pkgDir, "dist"),
      "--entry-naming",
      "install.js",
      "--target=node",
      "--format=esm",
      "--packages=bundle",
    ], { cwd: packageRoot, encoding: "utf8" })
    expect(built.status, built.stderr || built.stdout).toBe(0)

    await cp(path.join(packageRoot, "package.json"), path.join(pkgDir, "package.json"))
    await cp(path.join(packageRoot, "plugin", "inline"), path.join(pkgDir, "plugin", "inline"), { recursive: true })
    await mkdir(path.join(pkgDir, "plugin", "inline", "__pycache__"), { recursive: true })
    await writeFile(path.join(pkgDir, "plugin", "inline", "__pycache__", "adapter.cpython-312.pyc"), "bytecode")
    await writeFile(path.join(pkgDir, "plugin", "inline", "sidecar", "index.mjs.map"), "{}")
    await writeFile(path.join(pkgDir, "plugin", "inline", ".DS_Store"), "local")

    const result = spawnSync(nodeBin, [
      path.join(pkgDir, "dist", "install.js"),
      "install",
      "--hermes-home",
      home,
      "--force",
      "--json",
    ], {
      encoding: "utf8",
      env: { ...process.env, INLINE_NODE_BIN: nodeBin },
    })

    expect(result.status, result.stderr || result.stdout).toBe(0)
    const installed = path.join(home, "plugins", "inline")
    await expect(readFile(path.join(installed, "adapter.py"), "utf8")).resolves.toContain("class InlineAdapter")
    await expect(readFile(path.join(installed, "__pycache__", "adapter.cpython-312.pyc"), "utf8")).rejects.toThrow()
    await expect(readFile(path.join(installed, "sidecar", "index.mjs.map"), "utf8")).rejects.toThrow()
    await expect(readFile(path.join(installed, ".DS_Store"), "utf8")).rejects.toThrow()
  })

  it("returns nonzero from doctor when the installed plugin is missing", async () => {
    const home = await tempDir()
    vi.spyOn(console, "log").mockImplementation(() => {})

    const code = await main(["doctor", "--hermes-home", home])

    expect(code).toBe(1)
  })

  it("reports source and installed sidecar hashes", async () => {
    const home = await tempDir()
    const log = vi.spyOn(console, "log").mockImplementation(() => {})

    expect(await main(["install", "--hermes-home", home, "--force"])).toBe(0)
    await writeEnabledHermesConfig(home)
    const code = await main(["doctor", "--hermes-home", home, "--json"])

    expect(code).toBe(0)
    const payload = JSON.parse(String(log.mock.calls.at(-1)?.[0]))
    expect(payload.sidecar.source).toMatchObject({ exists: true })
    expect(payload.sidecar.target).toMatchObject({ exists: true })
    expect(payload.sidecar.source.sha256).toMatch(/^[a-f0-9]{64}$/)
    expect(payload.sidecar.target.sha256).toBe(payload.sidecar.source.sha256)
    expect(payload.activation).toMatchObject({
      configExists: true,
      pluginEnabled: true,
      platformConfigured: true,
      configTokenConfigured: false,
      tokenConfigured: false,
    })
    expect(payload.warnings).toContain("No Inline token was detected in INLINE_TOKEN, INLINE_BOT_TOKEN, or Hermes Inline config; live Inline realtime checks will not connect")
  })

  it("uses consistent env and config-token wording for runtime readiness warnings", async () => {
    const home = await tempDir()
    const log = vi.spyOn(console, "log").mockImplementation(() => {})

    expect(await main(["install", "--hermes-home", home, "--force"])).toBe(0)
    await writePluginEnabledConfig(home)
    const code = await main(["doctor", "--hermes-home", home, "--json"])

    expect(code).toBe(0)
    const payload = JSON.parse(String(log.mock.calls.at(-1)?.[0]))
    expect(payload.warnings).toContain("Inline platform config is not enabled. Add platforms.inline.enabled: true and set INLINE_TOKEN/INLINE_BOT_TOKEN in the gateway environment, or set platforms.inline.token/inline.token in Hermes config")
    expect(payload.warnings).toContain("No Inline token was detected in INLINE_TOKEN, INLINE_BOT_TOKEN, or Hermes Inline config; live Inline realtime checks will not connect")
  })

  it("treats a Hermes config token as runtime-ready without printing it", async () => {
    const home = await tempDir()
    const log = vi.spyOn(console, "log").mockImplementation(() => {})

    expect(await main(["install", "--hermes-home", home, "--force"])).toBe(0)
    await writeEnabledHermesConfig(home, { token: "fake-config-token" })
    const code = await main(["doctor", "--hermes-home", home, "--json"])

    expect(code).toBe(0)
    const text = String(log.mock.calls.at(-1)?.[0])
    const payload = JSON.parse(text)
    expect(payload.activation).toMatchObject({
      configTokenConfigured: true,
      tokenPresent: false,
      tokenConfigured: true,
    })
    expect(payload.warnings).toEqual([])
    expect(text).not.toContain("fake-config-token")
  })

  it("treats a Hermes config token env reference as runtime-ready without printing it", async () => {
    const home = await tempDir()
    const log = vi.spyOn(console, "log").mockImplementation(() => {})
    setEnv("INLINE_DOC_TOKEN", "fake-env-config-token")

    expect(await main(["install", "--hermes-home", home, "--force"])).toBe(0)
    await writeEnabledHermesConfig(home, { token: "${INLINE_DOC_TOKEN}" })
    const code = await main(["doctor", "--hermes-home", home, "--json"])

    expect(code).toBe(0)
    const text = String(log.mock.calls.at(-1)?.[0])
    const payload = JSON.parse(text)
    expect(payload.activation).toMatchObject({
      configTokenConfigured: true,
      tokenPresent: false,
      tokenConfigured: true,
    })
    expect(payload.warnings).toEqual([])
    expect(text).not.toContain("fake-env-config-token")
    expect(text).not.toContain("INLINE_DOC_TOKEN")
  })

  it("treats top-level inline.token config as runtime-ready without printing it", async () => {
    const home = await tempDir()
    const log = vi.spyOn(console, "log").mockImplementation(() => {})

    expect(await main(["install", "--hermes-home", home, "--force"])).toBe(0)
    await writeTopLevelInlineConfig(home, "fake-top-level-token")
    const code = await main(["doctor", "--hermes-home", home, "--json"])

    expect(code).toBe(0)
    const text = String(log.mock.calls.at(-1)?.[0])
    const payload = JSON.parse(text)
    expect(payload.activation).toMatchObject({
      platformConfigured: true,
      configTokenConfigured: true,
      tokenPresent: false,
      tokenConfigured: true,
    })
    expect(payload.warnings).toEqual([])
    expect(text).not.toContain("fake-top-level-token")
  })

  it("reports when the Hermes plugin has not been enabled", async () => {
    const home = await tempDir()
    const log = vi.spyOn(console, "log").mockImplementation(() => {})

    expect(await main(["install", "--hermes-home", home, "--force"])).toBe(0)
    const code = await main(["doctor", "--hermes-home", home, "--json"])

    expect(code).toBe(1)
    const payload = JSON.parse(String(log.mock.calls.at(-1)?.[0]))
    expect(payload.activation).toMatchObject({
      configExists: false,
      pluginEnabled: false,
    })
    expect(payload.issues).toContain("Hermes plugin 'inline-platform' is not enabled. Run: hermes plugins enable inline-platform")
  })

  it("validates an explicit INLINE_NODE_BIN in doctor output", async () => {
    const home = await tempDir()
    const missingNode = path.join(home, "missing-node")
    const log = vi.spyOn(console, "log").mockImplementation(() => {})

    expect(await main(["install", "--hermes-home", home, "--force"])).toBe(0)
    setEnv("INLINE_NODE_BIN", missingNode)
    const code = await main(["doctor", "--hermes-home", home, "--json"])

    expect(code).toBe(1)
    const payload = JSON.parse(String(log.mock.calls.at(-1)?.[0]))
    expect(payload.node).toMatchObject({
      path: missingNode,
      source: "INLINE_NODE_BIN",
      ok: false,
      exists: false,
    })
    expect(payload.issues).toContain(`INLINE_NODE_BIN does not exist: ${missingNode}`)
  })

  it("rejects Node versions older than the sidecar runtime requirement", async () => {
    const home = await tempDir()
    const fakeNode = path.join(home, "node18")
    const log = vi.spyOn(console, "log").mockImplementation(() => {})
    await writeFile(fakeNode, "#!/bin/sh\necho v18.19.0\n")
    await chmod(fakeNode, 0o755)

    expect(await main(["install", "--hermes-home", home, "--force"])).toBe(0)
    setEnv("INLINE_NODE_BIN", fakeNode)
    const code = await main(["doctor", "--hermes-home", home, "--json"])

    expect(code).toBe(1)
    const payload = JSON.parse(String(log.mock.calls.at(-1)?.[0]))
    expect(payload.node).toMatchObject({
      path: fakeNode,
      source: "INLINE_NODE_BIN",
      ok: false,
      exists: true,
      executable: true,
      version: "v18.19.0",
      major: 18,
    })
    expect(payload.issues).toContain("INLINE_NODE_BIN must be Node.js >=20; got v18.19.0")
  })

  it("fails doctor when the installed sidecar differs from the package sidecar", async () => {
    const home = await tempDir()
    const log = vi.spyOn(console, "log").mockImplementation(() => {})

    expect(await main(["install", "--hermes-home", home, "--force"])).toBe(0)
    await writeFile(path.join(home, "plugins", "inline", "sidecar", "index.mjs"), "stale sidecar")
    const code = await main(["doctor", "--hermes-home", home, "--json"])

    expect(code).toBe(1)
    const payload = JSON.parse(String(log.mock.calls.at(-1)?.[0]))
    expect(payload.issues).toContain("installed sidecar bundle does not match the package sidecar bundle")
  })

  it("plans test-send in dry-run mode without requiring a token", async () => {
    const home = await tempDir()
    setEnv("INLINE_TOKEN", "")
    setEnv("INLINE_BOT_TOKEN", "")
    const log = vi.spyOn(console, "log").mockImplementation(() => {})

    const code = await main(["test-send", "--hermes-home", home, "--to", "chat:123", "--dry-run", "--json"])

    expect(code).toBe(0)
    const payload = JSON.parse(String(log.mock.calls.at(-1)?.[0]))
    expect(payload).toMatchObject({
      ok: true,
      action: "test-send",
      target: { chatId: "123" },
      tokenPresent: false,
      dryRun: true,
      sent: false,
      issues: [],
    })
  })

  it("redacts credentialed test-send base URLs in JSON diagnostics", async () => {
    const home = await tempDir()
    setEnv("INLINE_TOKEN", "")
    setEnv("INLINE_BOT_TOKEN", "")
    const log = vi.spyOn(console, "log").mockImplementation(() => {})
    const baseUrl = "http://user:pass@127.0.0.1/mock?token=query-secret&apiToken=also-secret&ok=1"

    const code = await main([
      "test-send",
      "--hermes-home",
      home,
      "--to",
      "chat:123",
      "--dry-run",
      "--base-url",
      baseUrl,
      "--json",
    ])

    expect(code).toBe(0)
    const text = String(log.mock.calls.at(-1)?.[0])
    const payload = JSON.parse(text)
    expect(payload.baseUrl).toBe("http://redacted:redacted@127.0.0.1/mock?token=redacted&apiToken=redacted&ok=1")
    expect(text).not.toContain("query-secret")
    expect(text).not.toContain("also-secret")
    expect(text).not.toContain("user:pass")
  })

  it("redacts credentialed test-send base URLs in text diagnostics", async () => {
    const home = await tempDir()
    setEnv("INLINE_TOKEN", "")
    setEnv("INLINE_BOT_TOKEN", "")
    const log = vi.spyOn(console, "log").mockImplementation(() => {})
    const baseUrl = "http://user:pass@127.0.0.1/mock?token=query-secret&ok=1"

    const code = await main([
      "test-send",
      "--hermes-home",
      home,
      "--to",
      "chat:123",
      "--dry-run",
      "--base-url",
      baseUrl,
    ])

    expect(code).toBe(0)
    const text = log.mock.calls.map((call) => String(call[0])).join("\n")
    expect(text).toContain("base url: http://redacted:redacted@127.0.0.1/mock?token=redacted&ok=1")
    expect(text).not.toContain("query-secret")
    expect(text).not.toContain("user:pass")
  })

  it("refuses test-send without an Inline token", async () => {
    const home = await tempDir()
    setEnv("INLINE_TOKEN", "")
    setEnv("INLINE_BOT_TOKEN", "")
    const log = vi.spyOn(console, "log").mockImplementation(() => {})

    const code = await main(["test-send", "--hermes-home", home, "--to", "user:42", "--json"])

    expect(code).toBe(1)
    const payload = JSON.parse(String(log.mock.calls.at(-1)?.[0]))
    expect(payload).toMatchObject({
      ok: false,
      action: "test-send",
      target: { userId: "42" },
      tokenPresent: false,
      sent: false,
    })
    expect(payload.issues).toContain("Inline token is required in INLINE_TOKEN, INLINE_BOT_TOKEN, platforms.inline.token, or inline.token")
  })

  it("uses a Hermes config token env reference for test-send preflight without printing it", async () => {
    const home = await tempDir()
    const missingNode = path.join(home, "missing-node")
    setEnv("INLINE_TOKEN", "")
    setEnv("INLINE_BOT_TOKEN", "")
    setEnv("INLINE_CONFIG_TOKEN", "fake-env-config-token")
    setEnv("INLINE_NODE_BIN", missingNode)
    const log = vi.spyOn(console, "log").mockImplementation(() => {})

    await writeEnabledHermesConfig(home, { token: "${INLINE_CONFIG_TOKEN}" })
    const code = await main(["test-send", "--hermes-home", home, "--to", "user:42", "--json"])

    expect(code).toBe(1)
    const text = String(log.mock.calls.at(-1)?.[0])
    const payload = JSON.parse(text)
    expect(payload).toMatchObject({
      ok: false,
      action: "test-send",
      tokenPresent: true,
      sent: false,
      node: {
        path: missingNode,
        source: "INLINE_NODE_BIN",
        ok: false,
      },
    })
    expect(payload.issues).not.toContain("Inline token is required in INLINE_TOKEN, INLINE_BOT_TOKEN, platforms.inline.token, or inline.token")
    expect(text).not.toContain("fake-env-config-token")
    expect(text).not.toContain("INLINE_CONFIG_TOKEN")
  })

  it("uses top-level inline.token for test-send preflight without printing it", async () => {
    const home = await tempDir()
    const missingNode = path.join(home, "missing-node")
    setEnv("INLINE_TOKEN", "")
    setEnv("INLINE_BOT_TOKEN", "")
    setEnv("INLINE_NODE_BIN", missingNode)
    const log = vi.spyOn(console, "log").mockImplementation(() => {})

    await writeTopLevelInlineConfig(home, "fake-top-level-token")
    const code = await main(["test-send", "--hermes-home", home, "--to", "user:42", "--json"])

    expect(code).toBe(1)
    const text = String(log.mock.calls.at(-1)?.[0])
    const payload = JSON.parse(text)
    expect(payload).toMatchObject({
      ok: false,
      action: "test-send",
      tokenPresent: true,
      sent: false,
      node: {
        path: missingNode,
        source: "INLINE_NODE_BIN",
        ok: false,
      },
    })
    expect(payload.issues).not.toContain("Inline token is required in INLINE_TOKEN, INLINE_BOT_TOKEN, platforms.inline.token, or inline.token")
    expect(text).not.toContain("fake-top-level-token")
  })

  it("refuses live test-send before spawn when INLINE_NODE_BIN is invalid", async () => {
    const home = await tempDir()
    const missingNode = path.join(home, "missing-node")
    setEnv("INLINE_TOKEN", "fake-token")
    setEnv("INLINE_BOT_TOKEN", "")
    setEnv("INLINE_NODE_BIN", missingNode)
    const log = vi.spyOn(console, "log").mockImplementation(() => {})

    const code = await main(["test-send", "--hermes-home", home, "--to", "user:42", "--json"])

    expect(code).toBe(1)
    const payload = JSON.parse(String(log.mock.calls.at(-1)?.[0]))
    expect(payload).toMatchObject({
      ok: false,
      action: "test-send",
      tokenPresent: true,
      sent: false,
      node: {
        path: missingNode,
        source: "INLINE_NODE_BIN",
        ok: false,
        exists: false,
      },
    })
    expect(payload.issues).toContain(`INLINE_NODE_BIN does not exist: ${missingNode}`)
  })

  it("describes test-send readiness failures from sidecar health diagnostics", () => {
    expect(describeHealthFailure({
      result: {
        diagnostics: {
          protocol: {
            lastFailureReason: "server connection error (SESSION_REVOKED): SESSION_REVOKED",
          },
        },
      },
    })).toBe("server connection error (SESSION_REVOKED): SESSION_REVOKED")
    expect(describeHealthFailure({ result: { connectError: "invalid token" } })).toBe("invalid token")
  })
})

function setEnv(name: string, value: string): void {
  if (!envBefore.has(name)) {
    envBefore.set(name, process.env[name])
  }
  process.env[name] = value
}

async function writeEnabledHermesConfig(home: string, options: { token?: string } = {}): Promise<void> {
  await writeFile(path.join(home, "config.yaml"), [
    "plugins:",
    "  enabled:",
    "    - inline-platform",
    "platforms:",
    "  inline:",
    "    enabled: true",
    ...(options.token ? [`    token: ${JSON.stringify(options.token)}`] : []),
    "",
  ].join("\n"))
}

async function writePluginEnabledConfig(home: string): Promise<void> {
  await writeFile(path.join(home, "config.yaml"), [
    "plugins:",
    "  enabled:",
    "    - inline-platform",
    "",
  ].join("\n"))
}

async function writeTopLevelInlineConfig(home: string, token: string): Promise<void> {
  await writeFile(path.join(home, "config.yaml"), [
    "plugins:",
    "  enabled:",
    "    - inline-platform",
    "inline:",
    "  enabled: true",
    `  token: ${JSON.stringify(token)}`,
    "",
  ].join("\n"))
}

function restoreEnv(): void {
  for (const [name, value] of envBefore) {
    if (value === undefined) {
      delete process.env[name]
    } else {
      process.env[name] = value
    }
  }
  envBefore.clear()
}
