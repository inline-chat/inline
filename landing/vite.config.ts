import { defineConfig, type PluginOption } from "vite"
import { tanstackStart } from "@tanstack/react-start/plugin/vite"
import viteReact from "@vitejs/plugin-react"
import tsconfigPaths from "vite-tsconfig-paths"
import tailwindcss from "@tailwindcss/vite"
import stylex from "vite-plugin-stylex"
import { nitro } from "nitro/vite"

const host = process.env.TAURI_DEV_HOST

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
  },
})

export default config
