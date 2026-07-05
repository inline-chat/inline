import { execFileSync } from "node:child_process"
import { mkdir, mkdtemp, readFile, rm } from "node:fs/promises"
import os from "node:os"
import path from "node:path"
import { fileURLToPath } from "node:url"
import { describe, expect, it } from "vitest"

const packageRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..")
const realNpmEnv = { ...process.env, npm_config_dry_run: "false" }

type PackFile = {
  path: string
  mode: number
  size: number
}

type PackEntry = {
  name: string
  version: string
  filename: string
  files: PackFile[]
  entryCount: number
  unpackedSize: number
}

describe("packed artifact", () => {
  it("ships only runtime files and license text needed by the external Hermes plugin", async () => {
    const raw = execFileSync("npm", ["pack", "--dry-run", "--json", "--silent"], {
      cwd: packageRoot,
      encoding: "utf8",
      stdio: ["ignore", "pipe", "pipe"],
    })
    const pack = parsePackOutput(raw)
    const files = pack.files.map((file) => file.path).sort()

    expect(pack.name).toBe("@inline-chat/hermes-agent-adapter")
    expect(pack.entryCount).toBe(expectedFiles.length)
    expect(files).toEqual(expectedFiles)
    expect(pack.unpackedSize).toBeGreaterThan(1_000_000)

    for (const file of files) {
      expect(file).not.toMatch(/(?:^|\/)__pycache__\//)
      expect(file).not.toMatch(/\.(?:map|pyc|pyo|tsbuildinfo)$/)
      expect(file).not.toContain(".DS_Store")
      expect(file).not.toContain("coverage/")
      expect(file).not.toContain("tests/")
      expect(file).not.toContain("src/")
    }

    const installFile = pack.files.find((file) => file.path === "dist/install.js")
    expect(installFile?.mode).toBe(0o755)

    const license = await readFile(path.join(packageRoot, "LICENSE"), "utf8")
    expect(license).toContain("Apache License")

    const pkg = JSON.parse(await readFile(path.join(packageRoot, "package.json"), "utf8")) as {
      bin?: Record<string, string>
      engines?: Record<string, string>
      inlineHermes?: Record<string, string>
      repository?: { directory?: string }
      scripts?: Record<string, string>
    }
    expect(pkg.bin?.["inline-hermes"]).toBe("dist/install.js")
    expect(pkg.engines?.node).toBe(">=20")
    expect(pkg.repository?.directory).toBe("hermes-agent")
    expect(pkg.scripts?.prepublishOnly).toBe("bun run check")
    expect(pkg.scripts?.["release:preflight"]).toBe("npm publish --dry-run --access public")
    expect(pkg.inlineHermes).toMatchObject({
      pluginId: "inline",
      pluginPath: "plugin/inline",
      minHermesVersion: "0.17.0",
      testedHermesVersion: "0.17.0",
      testedHermesCommit: "824f2279",
    })

    const installJs = await readFile(path.join(packageRoot, "dist/install.js"), "utf8")
    expect(installJs).not.toContain("sourceMappingURL")

    const manifest = await readFile(path.join(packageRoot, "plugin/inline/plugin.yaml"), "utf8")
    expect(manifest).toContain("INLINE_BOT_TOKEN, platforms.inline.token, inline.token, and simple ${ENV_NAME} config references are also accepted")
    expect(manifest).toContain("INLINE_CONTEXT_BACKFILL")
    expect(manifest).toContain("INLINE_OBSERVE_UNMENTIONED_MESSAGES")
    expect(manifest).toContain("prompt: \"Inline token\"")

    const readme = await readFile(path.join(packageRoot, "README.md"), "utf8")
    expect(readme).toContain("https://inline.chat/docs/creating-a-bot")
    expect(readme).toContain("## Coding Agent Setup Prompt")
    expect(readme).toContain("## Update Or Reinstall")
    expect(readme).toContain("export INLINE_TOKEN=\"<token>\"")
    expect(readme).toContain("inline-hermes test-send --to chat:123 --text \"Inline Hermes test\"")
    expect(readme).not.toContain("INLINE_TOKEN=<token> inline-hermes test-send")
    expect(readme).toContain("inline-hermes install --force")
    expect(readme).toContain("hermes-agent/RELEASE.md")

    const release = await readFile(path.join(packageRoot, "RELEASE.md"), "utf8")
    expect(release).toContain("## Manual Live Test")
    expect(release).toContain("https://inline.chat/docs/creating-a-bot")
    expect(release).toContain("VERSION=\"$(node -p \"require('./package.json').version\")\"")
    expect(release).toContain("mkdir -p .tmp/manual-pack")
    expect(release).toContain("inline-chat-hermes-agent-adapter-${VERSION}.tgz")
    expect(release).toContain("npm publish --access public")

    const sidecar = await readFile(path.join(packageRoot, "plugin/inline/sidecar/index.mjs"), "utf8")
    expect(sidecar).toContain("inline-sidecar")
    expect(sidecar).toContain("x-hermes-sidecar-token")
    expect(sidecar).not.toContain("sourceMappingURL")
  }, 60_000)

  it("installs the packed tarball and runs the shipped inline-hermes bin", async () => {
    const dir = await mkdtemp(path.join(os.tmpdir(), "inline-hermes-pack-"))
    try {
      const packDir = path.join(dir, "pack")
      const prefix = path.join(dir, "prefix")
      const hermesHome = path.join(dir, "hermes")
      await mkdir(packDir, { recursive: true })
      await mkdir(prefix, { recursive: true })
      await mkdir(path.join(prefix, "bin"), { recursive: true })
      await mkdir(path.join(prefix, "lib"), { recursive: true })

      const raw = execFileSync("npm", ["pack", "--pack-destination", packDir, "--json", "--silent"], {
        cwd: packageRoot,
        encoding: "utf8",
        env: realNpmEnv,
        stdio: ["ignore", "pipe", "pipe"],
      })
      const pack = parsePackOutput(raw)
      const tarball = path.join(packDir, pack.filename)

      execFileSync("npm", ["install", "--global", "--prefix", prefix, tarball], {
        cwd: packageRoot,
        encoding: "utf8",
        env: realNpmEnv,
        stdio: ["ignore", "pipe", "pipe"],
      })

      const bin = process.platform === "win32"
        ? path.join(prefix, "inline-hermes.cmd")
        : path.join(prefix, "bin", "inline-hermes")
      const help = execFileSync(bin, ["help"], {
        cwd: packageRoot,
        encoding: "utf8",
        stdio: ["ignore", "pipe", "pipe"],
      })
      expect(help).toContain("inline-hermes install")
      expect(help).toContain("inline-hermes doctor")
      expect(help).toContain("inline-hermes test-send")
      expect(help).toContain("inline-hermes install --force")
      expect(help).toContain("inline-hermes version")

      const version = execFileSync(bin, ["--version"], {
        cwd: packageRoot,
        encoding: "utf8",
        stdio: ["ignore", "pipe", "pipe"],
      }).trim()
      expect(version).toBe("@inline-chat/hermes-agent-adapter@0.0.2")

      const install = execFileSync(bin, ["install", "--hermes-home", hermesHome, "--force", "--json"], {
        cwd: packageRoot,
        encoding: "utf8",
        stdio: ["ignore", "pipe", "pipe"],
      })
      const installJson = JSON.parse(install) as {
        ok?: boolean
        sourceValid?: boolean
        targetValid?: boolean
        sidecar?: { source?: { exists?: boolean }; target?: { exists?: boolean } }
      }
      expect(installJson.ok).toBe(true)
      expect(installJson.sourceValid).toBe(true)
      expect(installJson.targetValid).toBe(true)
      expect(installJson.sidecar?.source?.exists).toBe(true)
      expect(installJson.sidecar?.target?.exists).toBe(true)

      const dryRun = execFileSync(bin, [
        "test-send",
        "--dry-run",
        "--to",
        "chat:123",
        "--text",
        "Inline Hermes tarball dry-run",
        "--json",
      ], {
        cwd: packageRoot,
        encoding: "utf8",
        stdio: ["ignore", "pipe", "pipe"],
      })
      const dryRunJson = JSON.parse(dryRun) as {
        ok?: boolean
        dryRun?: boolean
        sent?: boolean
        tokenPresent?: boolean
        target?: { chatId?: string }
      }
      expect(dryRunJson.ok).toBe(true)
      expect(dryRunJson.dryRun).toBe(true)
      expect(dryRunJson.sent).toBe(false)
      expect(dryRunJson.tokenPresent).toBe(false)
      expect(dryRunJson.target?.chatId).toBe("123")
    } finally {
      await rm(dir, { recursive: true, force: true })
    }
  }, 120_000)
})

const expectedFiles = [
  "LICENSE",
  "README.md",
  "dist/install.d.ts",
  "dist/install.js",
  "package.json",
  "plugin/inline/__init__.py",
  "plugin/inline/adapter.py",
  "plugin/inline/cli.py",
  "plugin/inline/plugin.yaml",
  "plugin/inline/sidecar/index.mjs",
  "plugin/inline/tools.py",
]

function parsePackOutput(raw: string): PackEntry {
  const start = raw.indexOf("[")
  expect(start).toBeGreaterThanOrEqual(0)
  const parsed = JSON.parse(raw.slice(start)) as PackEntry[]
  expect(parsed).toHaveLength(1)
  return parsed[0]!
}
