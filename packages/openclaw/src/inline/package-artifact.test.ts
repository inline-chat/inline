import { mkdtemp, readdir, readFile } from "node:fs/promises"
import path from "node:path"
import { tmpdir } from "node:os"
import { execFile as execFileCallback } from "node:child_process"
import { promisify } from "node:util"
import { pathToFileURL } from "node:url"
import { describe, expect, it } from "vitest"

const execFile = promisify(execFileCallback)

async function listJsFiles(dir: string): Promise<string[]> {
  const entries = await readdir(dir, { withFileTypes: true })
  const files = await Promise.all(
    entries.map(async (entry) => {
      const entryPath = path.join(dir, entry.name)
      if (entry.isDirectory()) {
        return listJsFiles(entryPath)
      }
      if (entry.isFile() && entry.name.endsWith(".js")) {
        return [entryPath]
      }
      return []
    }),
  )
  return files.flat()
}

describe("packed artifact", () => {
  it("does not ship unresolved runtime package imports beyond OpenClaw SDK peers", async () => {
    const packDir = await mkdtemp(path.join(tmpdir(), "inline-openclaw-pack-"))
    const extractDir = await mkdtemp(path.join(tmpdir(), "inline-openclaw-extract-"))
    const packageDir = path.resolve(__dirname, "..", "..")

    const packResult = await execFile(
      "npm",
      ["pack", "--pack-destination", packDir],
      { cwd: packageDir },
    )
    const packedFile = packResult.stdout.trim().split("\n").at(-1)
    expect(packedFile).toBeTruthy()

    const tarballPath = path.join(packDir, packedFile!)
    await execFile("tar", ["-xzf", tarballPath, "-C", extractDir])

    const distDir = path.join(extractDir, "package", "dist")
    const jsFiles = await listJsFiles(distDir)
    expect(jsFiles.length).toBeGreaterThan(0)

    const distFiles = await readdir(distDir)
    expect(distFiles).toContain("index.js")
    expect(distFiles).toContain("configured-state.js")
    expect(distFiles).toContain("setup-entry.js")
    expect(distFiles).toContain("setup-plugin-api.js")
    expect(distFiles).toContain("secret-contract-api.js")
    expect(distFiles).toContain("channel-plugin-api.js")
    expect(distFiles).toContain("approval-handler.runtime.js")
    expect(distFiles).toContain("runtime-setter-api.js")
    expect(distFiles).toContain("account-inspect-api.js")
    expect(distFiles).toContain("runtime-register-api.js")
    expect(distFiles).not.toContain("tsconfig.tsbuildinfo")

    const mainEntry = await readFile(path.join(distDir, "index.js"), "utf8")
    expect(mainEntry).toContain("defineBundledChannelEntry")
    expect(mainEntry).toContain("channel-plugin-api.js")
    expect(mainEntry).toContain("secret-contract-api.js")
    expect(mainEntry).toContain("runtime-setter-api.js")
    expect(mainEntry).toContain("account-inspect-api.js")
    expect(mainEntry).toContain("runtime-register-api.js")
    expect(mainEntry).not.toContain("monitorInlineProvider")
    expect(mainEntry).not.toContain("starting Inline realtime monitor")

    const setupPluginApi = await readFile(path.join(distDir, "setup-plugin-api.js"), "utf8")
    expect(setupPluginApi).not.toContain("monitorInlineProvider")
    expect(setupPluginApi).not.toContain("starting Inline realtime monitor")
    expect(setupPluginApi).toContain("channels.inline.token")
    const setupEntry = await readFile(path.join(distDir, "setup-entry.js"), "utf8")
    expect(setupEntry).toContain("secret-contract-api.js")
    expect(setupEntry).toContain("channelSecrets")
    const secretContractApi = await readFile(path.join(distDir, "secret-contract-api.js"), "utf8")
    expect(secretContractApi).toContain("channelSecrets")
    const channelPluginApi = await readFile(path.join(distDir, "channel-plugin-api.js"), "utf8")
    expect(channelPluginApi).toContain("approval-handler.runtime.js")
    expect(channelPluginApi).not.toContain("src/inline/approval-handler.runtime.ts")
    expect(channelPluginApi).not.toContain("createChannelApprovalNativeRuntimeAdapter")
    const approvalHandlerRuntime = await readFile(
      path.join(distDir, "approval-handler.runtime.js"),
      "utf8",
    )
    expect(approvalHandlerRuntime).toContain("inlineApprovalNativeRuntime")
    expect(approvalHandlerRuntime).toContain("createChannelApprovalNativeRuntimeAdapter")

    const builtEntryUrl = pathToFileURL(path.join(packageDir, "dist", "index.js")).href
    const runtimeProbe = await execFile(
      process.execPath,
      [
        "--input-type=module",
        "-e",
        `
          const loaded = await import(${JSON.stringify(builtEntryUrl)});
          let registeredChannel = null;
          const runtime = {
            channel: {
              text: {
                chunkMarkdownText: (text, limit) => [text + ":" + limit],
              },
            },
          };
          loaded.default.register({
            registrationMode: "full",
            runtime,
            config: { channels: { inline: { token: "test-token" } } },
            logger: {
              info() {},
              warn() {},
              error() {},
            },
            registerChannel({ plugin }) {
              registeredChannel = plugin;
            },
            registerTool() {},
            on() {},
          });
          console.log(JSON.stringify({
            id: registeredChannel?.id,
            chunked: registeredChannel?.outbound?.chunker?.("hello", 4),
          }));
        `,
      ],
      { cwd: packageDir },
    )
    expect(JSON.parse(runtimeProbe.stdout)).toEqual({
      id: "inline",
      chunked: ["hello:4"],
    })

    const unresolvedBareImports = new Set<string>()
    const importPattern = /from\s+"([^"]+)"/g

    for (const file of jsFiles) {
      const contents = await readFile(file, "utf8")
      for (const match of contents.matchAll(importPattern)) {
        const specifier = match[1]
        if (
          specifier.startsWith("./") ||
          specifier.startsWith("../") ||
          specifier.startsWith("node:") ||
          specifier === "openclaw/plugin-sdk" ||
          specifier.startsWith("openclaw/plugin-sdk/")
        ) {
          continue
        }
        unresolvedBareImports.add(specifier)
      }
    }

    expect([...unresolvedBareImports]).toEqual([])
  }, 30_000)
})
