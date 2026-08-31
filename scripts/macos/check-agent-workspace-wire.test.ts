import { expect, test } from "bun:test"
import { mkdtemp } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join, resolve } from "node:path"

test.skipIf(process.platform !== "darwin")("the real Swift folder client uses the bridge wire contract", async () => {
  const directory = await mkdtemp(join(tmpdir(), "inline-workspace-wire-"))
  const main = join(directory, "Probe.swift")
  const executable = join(directory, "probe")
  await Bun.write(main, `
import Foundation
@main struct Probe {
  static func main() async throws {
    let port = UInt16(CommandLine.arguments[1])!
    let capability = String(repeating: "a", count: 32)
    guard await LocalAgentWorkspaceRegistrar.isAvailable(
      hostInstallationID: "host-test", botUserID: 84, port: port, capability: capability
    ) else { fatalError("probe rejected") }
    let id = try await LocalAgentWorkspaceRegistrar.register(
      folderURL: URL(fileURLWithPath: "/tmp/project"),
      hostInstallationID: "host-test", botUserID: 84, port: port, capability: capability
    )
    guard id == "workspace-test" else { fatalError("workspace ID did not decode") }
    print("workspace wire passed")
  }
}
`)
  const compile = Bun.spawn([
    "swiftc", "-swift-version", "6", "-parse-as-library",
    resolve(import.meta.dir, "../../apple/InlineMac/Services/LocalAgentWorkspaceRegistrar.swift"),
    main, "-o", executable,
  ], { stdout: "pipe", stderr: "pipe" })
  const compileError = await new Response(compile.stderr).text()
  expect(await compile.exited, compileError).toBe(0)
  const requests: Record<string, unknown>[] = []
  const server = Bun.listen<{ buffer: string }>({
    hostname: "127.0.0.1", port: 0,
    socket: {
      open(socket) { socket.data = { buffer: "" } },
      data(socket, data) {
        socket.data.buffer += data.toString()
        if (!socket.data.buffer.includes("\n")) return
        const request = JSON.parse(socket.data.buffer.trim())
        requests.push(request)
        socket.end(JSON.stringify(request.action === "probe"
          ? { version: 1, status: "available" }
          : { version: 1, status: "registered", workspaceId: "workspace-test" }) + "\n")
      },
    },
  })
  try {
    const run = Bun.spawn([executable, String(server.port)], { stdout: "pipe", stderr: "pipe" })
    const [stdout, stderr, exit] = await Promise.all([
      new Response(run.stdout).text(), new Response(run.stderr).text(), run.exited,
    ])
    expect(exit, stderr).toBe(0)
    expect(stdout.trim()).toBe("workspace wire passed")
    expect(requests).toEqual([
      { version: 1, action: "probe", hostInstallationId: "host-test", botUserId: 84, capability: "a".repeat(32) },
      { version: 1, action: "register", hostInstallationId: "host-test", botUserId: 84, capability: "a".repeat(32), path: "/tmp/project" },
    ])
  } finally {
    server.stop(true)
  }
}, 60_000)
