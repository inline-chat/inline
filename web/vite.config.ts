import { defineConfig } from "vite"
import { tanstackStart } from "@tanstack/react-start/plugin/vite"
import viteReact from "@vitejs/plugin-react"
import tsconfigPaths from "vite-tsconfig-paths"
import tailwindcss from "@tailwindcss/vite"
import stylex from "vite-plugin-stylex"
import { nitro } from "nitro/vite"

const host = process.env.TAURI_DEV_HOST

const config = {
  css: {
    postcss: "./postcss.config.cjs", // Vite will automatically pick this up
  },

  plugins: [
    tailwindcss(),
    // Enables Vite to resolve imports using path aliases.
    tsconfigPaths(),
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
    viteReact({
      // babel: {
      //   plugins: [
      //     [
      //       "@stylexjs/babel-plugin",
      //       {
      //         dev: process.env.NODE_ENV === "development",
      //         runtimeInjection: false,
      //         genConditionalClasses: true,
      //         treeshakeCompensation: true,
      //         useRemForFontSize: false,
      //         // unstable_moduleResolution: {
      //         //   type: "commonJS",
      //         // },
      //       },
      //     ],
      //   ],
      // },
    }),
  ] as unknown as import("vite").PluginOption[],

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

  nitro: {
    preset: "bun",
  },
} as unknown as import("vite").UserConfig

export default defineConfig(config)
