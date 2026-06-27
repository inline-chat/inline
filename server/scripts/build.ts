import { $ } from "bun"
import { resolve } from "path"
import { version } from "../package.json"

// https://coolify.io/docs/knowledge-base/environment-variables/
const sourceCommit = process.env["SOURCE_COMMIT"] || (await $`git rev-parse HEAD`.quiet()).text().trim() || "N/A"
const commitHash = sourceCommit === "N/A" ? "N/A" : sourceCommit.slice(0, 7)

console.info(`🚧 Building...`)

await Bun.build({
  entrypoints: [resolve(__dirname, "../src/index.ts")],
  outdir: resolve(__dirname, "../dist"),
  target: "bun",
  external: ["@aws-sdk/*", "sharp"],
  sourcemap: "external",
  define: {
    "process.env.NODE_ENV": JSON.stringify("production"),
    "process.env.BUILD_DATE": JSON.stringify(new Date().toISOString()),
    "process.env.GIT_COMMIT_HASH": JSON.stringify(commitHash),
    "process.env.GIT_COMMIT_SHA": JSON.stringify(sourceCommit),
    "process.env.VERSION": JSON.stringify(version),
  },
})

console.info(`✅ Build complete`)
