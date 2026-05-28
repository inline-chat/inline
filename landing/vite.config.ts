import { defineConfig, type PluginOption } from "vite"
import { tanstackStart } from "@tanstack/react-start/plugin/vite"
import viteReact from "@vitejs/plugin-react"
import tsconfigPaths from "vite-tsconfig-paths"
import tailwindcss from "@tailwindcss/vite"
import stylex from "vite-plugin-stylex"
import { nitro } from "nitro/vite"

const host = process.env.TAURI_DEV_HOST
const immutableAssetMaxAge = 60 * 60 * 24 * 365
const securityHeaders = {
  "Content-Security-Policy": [
    "default-src 'self'",
    "base-uri 'self'",
    "object-src 'none'",
    "frame-ancestors 'self'",
    "img-src 'self' data: blob: https:",
    "font-src 'self' data: https://fonts.gstatic.com",
    "style-src 'self' 'unsafe-inline' https://fonts.googleapis.com",
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
  tailwindcss(),
  // Enables Vite to resolve imports using path aliases.
  tsconfigPaths(),
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
