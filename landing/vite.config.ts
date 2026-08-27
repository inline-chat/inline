import { readFile } from "node:fs/promises"
import path from "node:path"
import { defineConfig, type Plugin, type PluginOption } from "vite"
import { tanstackStart } from "@tanstack/react-start/plugin/vite"
import viteReact from "@vitejs/plugin-react"
import tsconfigPaths from "vite-tsconfig-paths"
import tailwindcss from "@tailwindcss/vite"
import stylex from "vite-plugin-stylex"
import { nitro } from "nitro/vite"
import { parseDocsFrontMatter, serializeDocsFrontMatter } from "./src/docs/frontMatter"
import { listDocsMarkdownFiles } from "./src/docs/sourceFiles"

const host = process.env.TAURI_DEV_HOST
const immutableAssetMaxAge = 60 * 60 * 24 * 365
const docsContentModuleId = "virtual:inline-docs-content"
const resolvedDocsContentModuleId = `\0${docsContentModuleId}`

function docsContentPlugin(): Plugin {
  let contentDirectory = ""
  let includeDrafts = false

  return {
    name: "inline-docs-content",
    enforce: "pre",
    configResolved(config) {
      contentDirectory = path.join(config.root, "src/docs/content")
      includeDrafts = config.command === "serve"
    },
    configureServer(server) {
      server.watcher.add(contentDirectory)
    },
    resolveId(id) {
      if (id === docsContentModuleId) return resolvedDocsContentModuleId
    },
    async load(id) {
      if (id !== resolvedDocsContentModuleId) return

      const filenames = await listDocsMarkdownFiles(contentDirectory)
      const sources = await Promise.all(
        filenames.map(async (filename) => ({
          filename,
          frontMatter: parseDocsFrontMatter(await readFile(path.join(contentDirectory, filename), "utf8")).frontMatter,
        })),
      )
      const imports: string[] = []
      const entries: string[] = []
      let importIndex = 0
      for (const { filename, frontMatter } of sources) {
        const key = JSON.stringify(`./content/${filename}`)
        if (!includeDrafts && frontMatter.draft) {
          const unpublishedStub = serializeDocsFrontMatter({
            title: "Draft",
            description: "Unpublished documentation.",
            draft: true,
          })
          entries.push(`${key}: ${JSON.stringify(unpublishedStub)}`)
          continue
        }

        imports.push(`import docsSource${importIndex} from ${JSON.stringify(`/src/docs/content/${filename}?raw`)}`)
        entries.push(`${key}: docsSource${importIndex}`)
        importIndex += 1
      }
      return [...imports, `export default {${entries.join(",")}}`].join("\n")
    },
    handleHotUpdate({ file, server }) {
      if (!file.startsWith(`${contentDirectory}${path.sep}`)) return
      const module = server.moduleGraph.getModuleById(resolvedDocsContentModuleId)
      if (!module) return
      server.moduleGraph.invalidateModule(module)
      return [module]
    },
  }
}

const securityHeaders = {
  "Content-Security-Policy": [
    "default-src 'self'",
    "base-uri 'self'",
    "object-src 'none'",
    "frame-ancestors 'self'",
    "img-src 'self' data: blob: https:",
    "font-src 'self' data:",
    "style-src 'self' 'unsafe-inline'",
    "script-src 'self' 'unsafe-inline'",
    "connect-src 'self' https://api.inline.chat wss://api.inline.chat https://public-assets.inline.chat",
    "worker-src 'self' blob:",
    "manifest-src 'self'",
    "form-action 'self'",
    "upgrade-insecure-requests",
  ].join("; "),
  "Cross-Origin-Opener-Policy": "same-origin",
  "Cross-Origin-Resource-Policy": "same-origin",
  "Origin-Agent-Cluster": "?1",
  "Referrer-Policy": "no-referrer",
  "Strict-Transport-Security": "max-age=31536000; includeSubDomains",
  "X-Content-Type-Options": "nosniff",
  "X-DNS-Prefetch-Control": "off",
  "X-Download-Options": "noopen",
  "X-Frame-Options": "SAMEORIGIN",
  "X-Permitted-Cross-Domain-Policies": "none",
}

const plugins = [
  docsContentPlugin(),
  tailwindcss(),
  // Enables Vite to resolve imports using path aliases.
  tsconfigPaths({ projects: ["./tsconfig.json"] }),
  // @ts-ignore
  stylex({
    useCSSLayers: true,
  }),
  tanstackStart({
    srcDirectory: "src", // This is the default
    router: {
      // Specifies the directory TanStack Router uses for your routes.
      routesDirectory: "routes", // Defaults to "routes", relative to srcDirectory
    },
  }),
  nitro(),
  viteReact(),
] as unknown as PluginOption[]

const config = defineConfig({
  css: {
    postcss: "./postcss.config.cjs", // Vite will automatically pick this up
  },

  plugins,

  envPrefix: ["VITE_", "TAURI_"],

  build: {
    // Fixes missing styles in production build
    // Ref: https://github.com/vitejs/vite/issues/10630#issuecomment-1290273972
    cssCodeSplit: false,
  },

  server: {
    port: 8001,
    strictPort: true,
    host: host || false,
    hmr: host
      ? {
          protocol: "ws",
          host,
          port: 1421,
        }
      : undefined,
  },

  // @ts-ignore
  nitro: {
    preset: "bun",
    // The isolated runner passes a cross-realm Request through httpxy, whose
    // instanceof check fails and crashes every local route with "Invalid URL".
    devServer: {
      runner: "self",
    },
    routeRules: {
      "/**": {
        headers: securityHeaders,
      },
    },
    publicAssets: [
      {
        dir: "node_modules/.nitro/vite/services/ssr/assets",
        baseURL: "assets",
        maxAge: immutableAssetMaxAge,
        ignore: ["**/*.js"],
      },
    ],
  },
})

export default config
