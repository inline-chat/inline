import { execFileSync } from "node:child_process"
import { mkdtempSync, readFileSync, realpathSync, writeFileSync } from "node:fs"
import { createRequire } from "node:module"
import { tmpdir } from "node:os"
import path from "node:path"
import { fileURLToPath } from "node:url"

// Run against an installed, released host without changing workspace dependencies.
// Example: bun run check:host /path/to/node_modules/openclaw
const packageDir = fileURLToPath(new URL("..", import.meta.url))
const hostRoot = realpathSync(process.argv[2] ?? path.join(packageDir, "node_modules/openclaw"))
const host = JSON.parse(readFileSync(path.join(hostRoot, "package.json"), "utf8"))
if (host.name !== "openclaw") throw new Error("Expected an installed OpenClaw package")
const scratch = mkdtempSync(path.join(tmpdir(), "inline-openclaw-host-check-"))
const config = path.join(scratch, "tsconfig.json")
writeFileSync(config, JSON.stringify({
  extends: path.join(packageDir, "tsconfig.json"),
  compilerOptions: {
    typeRoots: [path.join(packageDir, "node_modules/@types")],
    paths: { "openclaw/plugin-sdk/*": [path.join(hostRoot, "dist/plugin-sdk/*.d.ts")] },
    tsBuildInfoFile: path.join(scratch, "tsconfig.tsbuildinfo"),
  },
}, null, 2))
const env = { ...process.env, OPENCLAW_COMPAT_HOST_ROOT: hostRoot }
const run = args => execFileSync("bun", args, { cwd: packageDir, env, stdio: "inherit" })
console.log(`Checking Inline source and packed runtime against OpenClaw ${host.version}`)
run([createRequire(import.meta.url).resolve("typescript/lib/tsc.js"), "-p", config, "--noEmit"])
run(["run", "test", "--coverage.enabled=false"])
