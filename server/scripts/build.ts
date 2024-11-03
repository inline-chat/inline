import { build, $ } from "bun"
import { resolve } from "path"
import { version } from "../package.json"

// https://coolify.io/docs/knowledge-base/environment-variables/
const commitHash =
  process.env["SOURCE_COMMIT"] || (await $`git rev-parse HEAD`.quiet()).text().trim().slice(0, 7) || "N/A"

// Migrate if run in production
if (process.env.NODE_ENV === "production") {
  console.log(`🚧 Migrating...`)
  try {
    await $`bun scripts/migrate.ts`.quiet()
  } catch (error) {
    console.error("🚨 Error migrating:", error)
    process.exit(1)
  }
}

console.log(`🚧 Building...`)

await Bun.build({
  entrypoints: [resolve(__dirname, "../src/index.ts")],
  outdir: resolve(__dirname, "../dist"),
  target: "bun",
  define: {
    "process.env.NODE_ENV": JSON.stringify("production"),
    "process.env.BUILD_DATE": JSON.stringify(new Date().toISOString()),
    "process.env.GIT_COMMIT_HASH": JSON.stringify(commitHash),
    "process.env.VERSION": JSON.stringify(version),
  },
})

console.log(`✅ Build complete`)
