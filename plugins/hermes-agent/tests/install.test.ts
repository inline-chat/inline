import { chmod, cp, mkdir, mkdtemp, readFile, realpath, readdir, rename, rm, lstat, symlink, writeFile } from "node:fs/promises"
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
    setEnv("INLINE_HERMES_BIN", path.join(os.tmpdir(), "missing-inline-hermes"))
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

  it("renders command-scoped help and rejects irrelevant cross-command flags", async () => {
    const log = vi.spyOn(console, "log").mockImplementation(() => {})

    for (const command of ["install", "status", "doctor", "test-send"] as const) {
      log.mockClear()
      await expect(main([command, "--help"])).resolves.toBe(0)
      expect(log.mock.calls.map((call) => String(call[0])).join("\n"))
        .toContain(`Usage: inline-hermes ${command}`)
    }

    await expect(main(["status", "--force"])).rejects.toThrow("--force is not valid for inline-hermes status")
    await expect(main(["doctor", "--dry-run"])).rejects.toThrow("--dry-run is not valid for inline-hermes doctor")
    await expect(main(["install", "--to", "chat:1"])).rejects.toThrow("--to is not valid for inline-hermes install")
    await expect(main(["test-send", "--link"])).rejects.toThrow("--link is not valid for inline-hermes test-send")
  })

  it("prints the package version from command or flag form", async () => {
    const log = vi.spyOn(console, "log").mockImplementation(() => {})

    await expect(main(["version"])).resolves.toBe(0)
    await expect(main(["--version"])).resolves.toBe(0)
    await expect(main(["-v"])).resolves.toBe(0)

    const versions = log.mock.calls.map((call) => String(call[0]))
    expect(versions).toEqual([
      "@inline-chat/hermes-agent-adapter@0.0.22",
      "@inline-chat/hermes-agent-adapter@0.0.22",
      "@inline-chat/hermes-agent-adapter@0.0.22",
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
    await expect(readFile(path.join(installed, "message_actions.py"), "utf8")).resolves.toContain("INLINE_AGENT_ACTION_PREFIX")
    await expect(readFile(path.join(installed, "sidecar", "index.mjs"), "utf8")).resolves.toContain("inline-sidecar")

    const log = vi.spyOn(console, "log").mockImplementation(() => {})
    expect(await main(["doctor", "--hermes-home", home, "--json"])).toBe(1)
    const payload = JSON.parse(String(log.mock.calls.at(-1)?.[0]))
    expect(payload.activation.installOwnershipAligned).toBe(true)
    expect(payload.warnings.join("\n")).not.toContain("manual updates may fail")
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

  it("only recommends a gateway restart after upgrading a configured install", async () => {
    const home = await tempDir()
    const log = vi.spyOn(console, "log").mockImplementation(() => {})
    await useFakeHermes(home, {
      action: "inline.status",
      setupProtocolVersion: 1,
      configured: true,
    })
    await writeEnabledHermesConfig(home)

    const code = await main(["install", "--hermes-home", home, "--force"])

    expect(code).toBe(0)
    const text = log.mock.calls.map((call) => String(call[0])).join("\n")
    expect(text).toContain("Restart the Hermes gateway")
    expect(text).not.toContain("hermes plugins enable")
    expect(text).not.toContain("hermes gateway setup")
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

  it("inspects the actual packed install once after every runtime byte is copied", async () => {
    // Retain this small packed fixture so a matching-core CLI can also exercise
    // the exact shipped installer, independently of the probe observer below.
    const dir = await mkdtemp(path.join(os.tmpdir(), "inline-hermes-install-proof-"))
    const pkgDir = path.join(dir, "pkg")
    const extracted = path.join(dir, "extracted")
    const consumer = path.join(dir, "consumer")
    const home = path.join(dir, "hermes")
    await mkdir(path.join(pkgDir, "dist"), { recursive: true })
    await mkdir(path.join(pkgDir, "plugin"), { recursive: true })
    await mkdir(extracted)
    const built = spawnSync("bun", ["build", "./src/install.ts", "--outdir", path.join(pkgDir, "dist"),
      "--entry-naming", "install.js", "--target=node", "--format=esm", "--packages=bundle"],
    { cwd: packageRoot, encoding: "utf8" })
    expect(built.status, "The current installer must bundle successfully").toBe(0)
    await cp(path.join(packageRoot, "package.json"), path.join(pkgDir, "package.json"))
    await cp(path.join(packageRoot, "plugin", "inline"), path.join(pkgDir, "plugin", "inline"), { recursive: true })
    const packed = spawnSync("npm", ["pack", "--ignore-scripts", "--json", "--silent", "--pack-destination", dir],
      { cwd: pkgDir, encoding: "utf8", env: { ...process.env, npm_config_dry_run: "false" } })
    expect(packed.status, "The current installer fixture must pack successfully").toBe(0)
    const tarball = path.join(dir, JSON.parse(packed.stdout)[0].filename)
    const unpacked = spawnSync("tar", ["-xzf", tarball, "-C", extracted], { encoding: "utf8" })
    expect(unpacked.status).toBe(0)
    const shipped = path.join(consumer, "node_modules", "@inline-chat", "hermes-agent-adapter")
    await mkdir(path.dirname(shipped), { recursive: true })
    await rename(path.join(extracted, "package"), shipped)
    await mkdir(path.join(consumer, "node_modules", ".bin"))
    await symlink(path.join(shipped, "dist", "install.js"), path.join(consumer, "node_modules", ".bin", "inline-hermes"))
    const source = path.join(shipped, "plugin", "inline")
    const probeLog = path.join(dir, "probes.jsonl")
    const hermes = path.join(dir, "observe-hermes")
    await writeFile(hermes, `#!${nodeBin}\n` + String.raw`
const { appendFileSync, readFileSync, readdirSync } = require("node:fs");
const path = require("node:path");
const source = ${JSON.stringify(source)};
const target = path.join(process.env.HERMES_HOME, "plugins", "inline");
const files = [];
function visit(directory, prefix = "") {
  for (const entry of readdirSync(directory, { withFileTypes: true })) {
    const name = path.join(prefix, entry.name);
    if (entry.isDirectory()) visit(path.join(directory, entry.name), name);
    else files.push(name);
  }
}
visit(source);
const equal = files.every(name => {
  try { return readFileSync(path.join(source, name)).equals(readFileSync(path.join(target, name))); }
  catch { return false; }
});
appendFileSync(${JSON.stringify(probeLog)}, JSON.stringify({ args: process.argv.slice(2), allRuntimeBytesMatch: equal }) + "\n");
console.log(JSON.stringify({ action: "inline.status", setupProtocolVersion: 1, configured: false }));
`)
    await chmod(hermes, 0o755)
    const bin = path.join(shipped, "dist", "install.js")
    const result = spawnSync(nodeBin, [bin, "install", "--hermes-home", home, "--json"], {
      encoding: "utf8", timeout: 30_000,
      env: { ...process.env, INLINE_NODE_BIN: nodeBin, INLINE_HERMES_BIN: hermes },
    })
    expect(result.status, "The packed installer must complete normally").toBe(0)
    const probes = (await readFile(probeLog, "utf8")).trim().split("\n").map(line => JSON.parse(line))
    expect(probes).toEqual([{ args: ["inline", "status", "--json"], allRuntimeBytesMatch: true }])
    const files = await readdir(source, { recursive: true, withFileTypes: true })
    for (const file of files.filter(entry => entry.isFile())) {
      const relative = path.relative(source, path.join(file.parentPath, file.name))
      expect(await readFile(path.join(home, "plugins", "inline", relative)))
        .toEqual(await readFile(path.join(source, relative)))
    }
    if (process.env.INLINE_HERMES_INSTALL_TEST_REPORT) {
      await writeFile(process.env.INLINE_HERMES_INSTALL_TEST_REPORT, JSON.stringify({
        case: "packed-installer-single-post-copy-inspection", bin, tarball, source, consumer,
        hermesHome: home, probes, runtimeFiles: files.filter(entry => entry.isFile()).length,
        allRuntimeBytesMatch: true, canonicalProbeExecutedBy: "test observer; real host is a separate assertion",
      }, null, 2) + "\n")
    }
  }, 30_000)

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

  it("fails closed when status targets a missing or incomplete install", async () => {
    const home = await tempDir()
    const log = vi.spyOn(console, "log").mockImplementation(() => {})

    expect(await main(["status", "--hermes-home", home, "--json"])).toBe(1)
    const missing = JSON.parse(String(log.mock.calls.at(-1)?.[0]))
    expect(missing).toMatchObject({
      ok: false,
      sourceReady: true,
      targetExists: false,
      targetValid: false,
      installedReady: false,
    })
    expect(missing.issues).toContain(`plugin is not installed: ${path.join(home, "plugins", "inline")}`)

    await mkdir(path.join(home, "plugins", "inline"), { recursive: true })
    await writeFile(path.join(home, "plugins", "inline", "plugin.yaml"), "name: incomplete\n")
    expect(await main(["status", "--hermes-home", home, "--json"])).toBe(1)
    const incomplete = JSON.parse(String(log.mock.calls.at(-1)?.[0]))
    expect(incomplete).toMatchObject({
      ok: false,
      targetExists: true,
      targetValid: false,
      installedReady: false,
    })
    expect(incomplete.issues).toContain(`installed plugin is incomplete: ${path.join(home, "plugins", "inline")}`)
  })

  it("reports source and installed sidecar hashes", async () => {
    const home = await tempDir()
    const log = vi.spyOn(console, "log").mockImplementation(() => {})

    expect(await main(["install", "--hermes-home", home, "--force"])).toBe(0)
    await writeEnabledHermesConfig(home)
    const code = await main(["doctor", "--hermes-home", home, "--json"])

    expect(code).toBe(1)
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
      credentialState: "unknown",
      tokenConfigured: false,
    })
    expect(payload.warnings).not.toContain("No Inline token was detected in INLINE_TOKEN, INLINE_BOT_TOKEN, the Hermes credential store, or Hermes Inline config; live Inline realtime checks will not connect")
  })

  it("does not report a missing credential when canonical Hermes status is unavailable", async () => {
    const home = await tempDir()
    const log = vi.spyOn(console, "log").mockImplementation(() => {})

    expect(await main(["install", "--hermes-home", home, "--force"])).toBe(0)
    await writePluginEnabledConfig(home)
    const code = await main(["doctor", "--hermes-home", home, "--json"])

    expect(code).toBe(1)
    const payload = JSON.parse(String(log.mock.calls.at(-1)?.[0]))
    expect(payload.activation.credentialState).toBe("unknown")
    expect(payload.warnings).not.toContain("Inline platform config is not enabled. Add platforms.inline.enabled: true and set INLINE_TOKEN/INLINE_BOT_TOKEN in the gateway environment, or set platforms.inline.token/inline.token in Hermes config")
    expect(payload.warnings).not.toContain("No Inline token was detected in INLINE_TOKEN, INLINE_BOT_TOKEN, the Hermes credential store, or Hermes Inline config; live Inline realtime checks will not connect")
  })

  it("uses canonical Hermes machine status without printing the credential", async () => {
    const home = await tempDir()
    const log = vi.spyOn(console, "log").mockImplementation(() => {})
    await useFakeHermes(home, {
      action: "inline.status",
      setupProtocolVersion: 1,
      configured: true,
      probe: {
        ok: true,
        botUserId: "42",
        botUsername: "machine_bot",
      },
    })

    expect(await main(["install", "--hermes-home", home, "--force"])).toBe(0)
    await writeEnabledHermesConfig(home)
    const code = await main(["doctor", "--hermes-home", home, "--json"])

    expect(code).toBe(0)
    const text = String(log.mock.calls.at(-1)?.[0])
    const payload = JSON.parse(text)
    expect(payload.activation).toMatchObject({
      hermesReceivingSupported: true,
      hermesCredentialStoreChecked: true,
      hermesCredentialStoreTokenConfigured: true,
      credentialState: "verified",
      credentialBotUserId: "42",
      credentialBotUsername: "machine_bot",
      tokenConfigured: true,
    })
    expect(payload.warnings).toEqual([])
    expect(text).not.toContain("secret-token")
  })

  it.each([
    ["missing core attestation", undefined],
    ["stock host", { supported: false, requiredIntakeVersion: 1, reason: "durable_intake_required" }],
    ["wrong capability version", { supported: true, requiredIntakeVersion: 2 }],
  ])("fails receiving doctor with %s while preserving verified sender readiness", async (_name, receivingCapability) => {
    const home = await tempDir()
    const log = vi.spyOn(console, "log").mockImplementation(() => {})
    await useFakeHermes(home, {
      action: "inline.status", setupProtocolVersion: 1, configured: true,
      receivingCapability, probe: { ok: true, botUserId: "42" },
    })
    expect(await main(["install", "--hermes-home", home, "--force"])).toBe(0)
    await writeEnabledHermesConfig(home)
    expect(await main(["doctor", "--hermes-home", home, "--json"])).toBe(1)
    const payload = JSON.parse(String(log.mock.calls.at(-1)?.[0]))
    expect(payload.activation).toMatchObject({
      hermesCompatibilityVerified: true, hermesReceivingSupported: false,
      credentialState: "verified", credentialBotUserId: "42",
    })
    expect(payload.issues.join(" ")).toContain("Hermes durable receiving support is unavailable")
  })

  it.each([
    ["missing attestation", undefined, 0],
    ["failed host loader", { ok: false, reason: "plugin_load_failed" }, 0],
    ["another plugin path", { ok: true, pluginPath: "/wrong/plugin" }, 0],
    ["failed subprocess", "valid", 1],
  ])("fails doctor with %s despite successful credential verification", async (_name, compatibility, exitCode) => {
    const home = await tempDir()
    const log = vi.spyOn(console, "log").mockImplementation(() => {})
    await useFakeHermes(home, {
      action: "inline.status",
      setupProtocolVersion: 1,
      configured: true,
      ...(compatibility === "valid" ? {} : { compatibility }),
      probe: { ok: true, botUserId: "42" },
    }, Number(exitCode))
    expect(await main(["install", "--hermes-home", home, "--force"])).toBe(0)
    await writeEnabledHermesConfig(home)
    expect(await main(["doctor", "--hermes-home", home, "--json"])).toBe(1)
    const text = String(log.mock.calls.at(-1)?.[0])
    const payload = JSON.parse(text)
    expect(payload.activation.hermesCompatibilityVerified).toBe(false)
    expect(payload.issues.join(" ")).toContain("could not validate the installed plugin compatibility")
    expect(text).not.toContain("secret-token")
  })

  it("requires a successful host load and rejects deprecated imports without exposing errors", () => {
    const script = String.raw`
import importlib.util
import pathlib
import sys
import types

plugin_dir = pathlib.Path(${JSON.stringify(path.join(packageRoot, "plugin", "inline"))}).resolve()
spec = importlib.util.spec_from_file_location("inline_doctor_test", plugin_dir / "cli.py")
cli = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cli)
hermes = types.ModuleType("hermes_cli")
hermes.__path__ = []
plugins = types.ModuleType("hermes_cli.plugins")
compat = types.ModuleType("hermes_cli.plugin_compat")
sys.modules.update({"hermes_cli": hermes, "hermes_cli.plugins": plugins, "hermes_cli.plugin_compat": compat})
manifest = types.SimpleNamespace(name="inline-platform", path=plugin_dir)
loaded = types.SimpleNamespace(manifest=manifest, enabled=True, error=None, module=object(), tools_registered=["inline"])
manager = types.SimpleNamespace(_plugins={"inline": loaded}, discover_and_load=lambda: None)
plugins.get_plugin_manager = lambda: manager
compat.plugin_hits = lambda _manifest: []
assert cli._compatibility_status() == {"ok": True, "reason": "loaded", "pluginPath": str(plugin_dir)}
compat.plugin_hits = lambda _manifest: [object()]
assert cli._compatibility_status()["reason"] == "deprecated_imports"
# Upstream main keeps updater stubs but has removed the scanner exports.
del compat.plugin_hits
assert cli._compatibility_status() == {"ok": True, "reason": "loaded", "pluginPath": str(plugin_dir)}
loaded.tools_registered = []
assert cli._compatibility_status()["reason"] == "tool_not_registered"
loaded.tools_registered = ["inline"]
loaded.error = "secret-token"
assert cli._compatibility_status() == {"ok": False, "reason": "plugin_load_failed"}
loaded.error = None
loaded.module = None
assert cli._compatibility_status()["reason"] == "plugin_load_failed"
loaded.module = object()
manifest.path = plugin_dir / "another-copy"
assert cli._compatibility_status()["reason"] == "plugin_not_loaded"
def broken():
    raise RuntimeError("secret-token")
manager.discover_and_load = broken
assert cli._compatibility_status() == {"ok": False, "reason": "loader_unavailable"}
`
    const result = spawnSync("python3", ["-c", script], { encoding: "utf8" })
    expect(result.status, result.stderr).toBe(0)
    expect(result.stdout).not.toContain("secret-token")
  })

  it("distinguishes a canonical missing credential from unavailable introspection", async () => {
    const home = await tempDir()
    const log = vi.spyOn(console, "log").mockImplementation(() => {})
    await useFakeHermes(home, {
      action: "inline.status",
      setupProtocolVersion: 1,
      configured: false,
    })

    expect(await main(["install", "--hermes-home", home, "--force"])).toBe(0)
    await writeEnabledHermesConfig(home)
    const code = await main(["doctor", "--hermes-home", home, "--json"])

    expect(code).toBe(1)
    const payload = JSON.parse(String(log.mock.calls.at(-1)?.[0]))
    expect(payload.activation).toMatchObject({
      credentialState: "not_configured",
      tokenConfigured: false,
    })
    expect(payload.issues).toContain("Hermes reports that no Inline credential is configured; run `hermes inline setup`")
  })

  it("fails doctor when the canonical probe identifies an invalid credential", async () => {
    const home = await tempDir()
    const log = vi.spyOn(console, "log").mockImplementation(() => {})
    await useFakeHermes(home, {
      action: "inline.status",
      setupProtocolVersion: 1,
      configured: true,
      probe: {
        ok: false,
        errorKind: "invalid_credential",
      },
    })

    expect(await main(["install", "--hermes-home", home, "--force"])).toBe(0)
    await writeEnabledHermesConfig(home)
    const code = await main(["doctor", "--hermes-home", home, "--json"])

    expect(code).toBe(1)
    const payload = JSON.parse(String(log.mock.calls.at(-1)?.[0]))
    expect(payload.activation.credentialState).toBe("invalid")
    expect(payload.issues).toContain("Hermes found the Inline credential, but Inline rejected it; reconfigure the credential")
  })

  it("fails doctor when canonical credential verification is inconclusive", async () => {
    const home = await tempDir()
    const log = vi.spyOn(console, "log").mockImplementation(() => {})
    await useFakeHermes(home, {
      action: "inline.status",
      setupProtocolVersion: 1,
      configured: true,
      probe: {
        ok: false,
        errorKind: "unavailable",
      },
    })

    expect(await main(["install", "--hermes-home", home, "--force"])).toBe(0)
    await writeEnabledHermesConfig(home)
    const code = await main(["doctor", "--hermes-home", home, "--json"])

    expect(code).toBe(1)
    const payload = JSON.parse(String(log.mock.calls.at(-1)?.[0]))
    expect(payload.activation).toMatchObject({
      hermesCredentialStoreChecked: true,
      credentialState: "unknown",
      tokenConfigured: true,
    })
    expect(payload.issues).toContain("Hermes found the Inline credential, but the requested verification was inconclusive")
  })

  it("keeps YAML credential fallback when canonical status reports not configured", async () => {
    const home = await tempDir()
    const log = vi.spyOn(console, "log").mockImplementation(() => {})
    await useFakeHermes(home, {
      action: "inline.status",
      setupProtocolVersion: 1,
      configured: false,
    })

    expect(await main(["install", "--hermes-home", home, "--force"])).toBe(0)
    await writeEnabledHermesConfig(home, { token: "yaml-only-token" })
    const code = await main(["doctor", "--hermes-home", home, "--json"])

    expect(code).toBe(0)
    const text = String(log.mock.calls.at(-1)?.[0])
    const payload = JSON.parse(text)
    expect(payload.activation).toMatchObject({
      credentialState: "configured_unverified",
      configTokenConfigured: true,
      tokenConfigured: true,
    })
    expect(text).not.toContain("yaml-only-token")
  })

  it("does not accept a config token as proof of Hermes compatibility", async () => {
    const home = await tempDir()
    const log = vi.spyOn(console, "log").mockImplementation(() => {})

    expect(await main(["install", "--hermes-home", home, "--force"])).toBe(0)
    await writeEnabledHermesConfig(home, { token: "fake-config-token" })
    const code = await main(["doctor", "--hermes-home", home, "--json"])

    expect(code).toBe(1)
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

  it("does not accept an env token reference as proof of Hermes compatibility", async () => {
    const home = await tempDir()
    const log = vi.spyOn(console, "log").mockImplementation(() => {})
    setEnv("INLINE_DOC_TOKEN", "fake-env-config-token")

    expect(await main(["install", "--hermes-home", home, "--force"])).toBe(0)
    await writeEnabledHermesConfig(home, { token: "${INLINE_DOC_TOKEN}" })
    const code = await main(["doctor", "--hermes-home", home, "--json"])

    expect(code).toBe(1)
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

  it("does not accept a top-level config token as proof of Hermes compatibility", async () => {
    const home = await tempDir()
    const log = vi.spyOn(console, "log").mockImplementation(() => {})

    expect(await main(["install", "--hermes-home", home, "--force"])).toBe(0)
    await writeTopLevelInlineConfig(home, "fake-top-level-token")
    const code = await main(["doctor", "--hermes-home", home, "--json"])

    expect(code).toBe(1)
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

async function useFakeHermes(home: string, payload: Record<string, unknown>, exitCode = 0): Promise<void> {
  const executable = path.join(home, "fake-hermes")
  const response = {
    compatibility: { ok: true, pluginPath: path.join(await realpath(home), "plugins", "inline") },
    receivingCapability: { supported: true, requiredIntakeVersion: 1, reason: "core_capability_available" },
    ...payload,
  }
  const encoded = JSON.stringify(response).replaceAll("'", "'\\''")
  await writeFile(executable, `#!/bin/sh\nprintf '%s\\n' 'secret-token' >&2\nprintf '%s\\n' '${encoded}'\nexit ${exitCode}\n`)
  await chmod(executable, 0o755)
  setEnv("INLINE_HERMES_BIN", executable)
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
