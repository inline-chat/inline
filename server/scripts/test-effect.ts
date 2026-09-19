import { resolve } from "node:path"
import { createTestEnvironment } from "./test-environment"

const serverRoot = resolve(import.meta.dir, "..")
const child = Bun.spawn({
  cmd: [resolve(serverRoot, "node_modules/.bin/vitest"), "run", "--config", "vitest.effect.config.ts", ...process.argv.slice(2)],
  cwd: serverRoot,
  env: createTestEnvironment(process.env),
  stdin: "inherit", stdout: "inherit", stderr: "inherit",
})
process.on("SIGINT", () => child.kill("SIGINT"))
process.on("SIGTERM", () => child.kill("SIGTERM"))
process.exit(await child.exited)
