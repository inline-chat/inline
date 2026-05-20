import { copyFileSync, existsSync, mkdirSync, readFileSync, readdirSync } from "node:fs"
import { join } from "node:path"

const ssrAssetsDir = join(process.cwd(), "node_modules/.nitro/vite/services/ssr/assets")
const publicAssetsDir = join(process.cwd(), ".output/public/assets")
const serverEntry = join(process.cwd(), ".output/server/index.mjs")

if (existsSync(ssrAssetsDir) && existsSync(publicAssetsDir)) {
  mkdirSync(publicAssetsDir, { recursive: true })

  const cssFiles = readdirSync(ssrAssetsDir).filter((file) => file.endsWith(".css"))

  for (const file of cssFiles) {
    copyFileSync(join(ssrAssetsDir, file), join(publicAssetsDir, file))
  }

  if (existsSync(serverEntry)) {
    const server = readFileSync(serverEntry, "utf8")
    const missing = cssFiles.filter((file) => !server.includes(`"/assets/${file}"`))

    if (missing.length > 0) {
      console.error(
        `SSR CSS assets were copied after Nitro generated its static asset manifest: ${missing.join(", ")}`,
      )
      console.error("Add them through nitro.publicAssets before the Nitro server build.")
      process.exit(1)
    }
  }
}
