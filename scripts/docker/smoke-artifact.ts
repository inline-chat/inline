import { access } from "node:fs/promises"
import { createRequire } from "node:module"
import { resolve } from "node:path"

// Runs against the final image's production dependencies. No external services
// or production credentials are needed; full server behavior is covered by its
// existing database-backed artifact smoke in CI.
const target = process.argv[2]
if (!["landing", "server", "mcp"].includes(target ?? "")) {
  throw new Error("Usage: bun scripts/docker/smoke-artifact.ts <landing|server|mcp>")
}

if (target === "server") {
  for (const file of [
    "server/dist/index.js",
    "server/dist/core-production-smoke.js",
    "server/dist/encrypt-content.js",
    "server/dist/migrate.js",
    "server/dist/verify-migrations.js",
    "server/dist/livekit-cutover-preflight.js",
    "server/scripts/start-production.ts",
    "server/scripts/verify-migrations.ts",
    "server/drizzle/meta/_journal.json",
    "packages/protocol/dist/index.js",
    "packages/oauth-core/dist/index.js",
  ]) await access(file)
  // Run the actual bundled CLI import graphs with no credentials or network.
  for (const command of ["migrate", "verify-migrations", "livekit-cutover-preflight"]) {
    for (const file of [`server/dist/${command}.js`, `server/scripts/${command}.ts`]) {
      const child = Bun.spawn([process.execPath, "--no-env-file", file, "--help"], {
        env: { PATH: process.env.PATH }, stdout: "pipe", stderr: "pipe",
      })
      const output = await new Response(child.stdout).text()
      const error = await new Response(child.stderr).text()
      const expectedExit = command === "livekit-cutover-preflight" ? 2 : 0
      if (await child.exited !== expectedExit || !(output + error).includes("Usage:")) {
        throw new Error(`Packaged command failed to load: ${file}: ${error}`)
      }
    }
  }
  const require = createRequire(resolve("server/package.json"))
  // Exercise the native payload, not just the JavaScript package entrypoint.
  await require("sharp")({ create: { width: 1, height: 1, channels: 3, background: "white" } }).png().toBuffer()
  // MessagePack belongs to Effect's dependency graph. Resolve from its owner
  // so this works with both isolated local installs and hoisted image installs.
  const { pack, unpack } = createRequire(require.resolve("effect"))("msgpackr")
  if (unpack(pack({ smoke: true })).smoke !== true) throw new Error("MessagePack smoke failed")
  console.info("Server image packaging and native dependencies passed.")
} else {
  const reservation = Bun.serve({ port: 0, hostname: "127.0.0.1", fetch: () => new Response() })
  const port = reservation.port!
  reservation.stop(true)
  const cwd = resolve(target === "landing" ? "landing" : "packages/mcp")
  const child = Bun.spawn({
    cmd: [process.execPath, target === "landing" ? ".output/server/index.mjs" : "dist/main.js"],
    cwd,
    env: { PATH: process.env.PATH, NODE_ENV: "production", PORT: String(port), HOST: "127.0.0.1" },
    stdout: "ignore",
    stderr: "ignore",
  })
  const headers = target === "mcp" ? { Host: "mcp.inline.chat" } : undefined
  const paths = target === "landing" ? ["/", "/docs"] : ["/health", "/.well-known/oauth-protected-resource"]
  try {
    const deadline = Date.now() + 15_000
    let ready = false
    while (Date.now() < deadline && child.exitCode === null) {
      try {
        const response = await fetch(`http://127.0.0.1:${port}${paths[0]}`, {
          headers, signal: AbortSignal.timeout(1_000),
        })
        ready = response.ok
        await response.body?.cancel()
        if (ready) break
      } catch { /* Process is still starting. */ }
      await Bun.sleep(100)
    }
    if (!ready) throw new Error(`${target} artifact did not become ready (exit ${child.exitCode}).`)
    for (const path of paths) {
      const response = await fetch(`http://127.0.0.1:${port}${path}`, {
        headers, signal: AbortSignal.timeout(3_000),
      })
      if (!response.ok) throw new Error(`${target} ${path}: HTTP ${response.status}`)
      const body = await response.text()
      if (target === "landing" && !body.toLowerCase().includes("<html")) throw new Error(`${path}: missing HTML`)
      if (target === "mcp") JSON.parse(body)
    }
    console.info(`${target} production artifact HTTP smoke passed.`)
  } finally {
    child.kill("SIGTERM")
    const timeout = setTimeout(() => child.kill("SIGKILL"), 3_000)
    await child.exited
    clearTimeout(timeout)
  }
}
