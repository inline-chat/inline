import stylex from "@stylexjs/unplugin"
import { tanstackStart } from "@tanstack/react-start/plugin/vite"
import viteReact from "@vitejs/plugin-react"
import { defineConfig } from "vite"
import { inlineBrowserHarnessPlugin } from "./tests/browser/InlineBrowserHarnessPlugin"

export default defineConfig({
  plugins: [
    inlineBrowserHarnessPlugin(),
    stylex.vite({
      devMode: "full",
      useCSSLayers: true,
    }),
    tanstackStart({
      server: {
        entry: "server.ts",
      },
      spa: {
        enabled: true,
      },
    }),
    viteReact(),
  ],
  resolve: {
    alias: {
      "~": new URL("./src", import.meta.url).pathname,
    },
  },
  server: {
    port: 8001,
    strictPort: true,
    watch: {
      // Browser/acceptance runs share the workspace but not the product
      // server. Trace and report writes must never reload the real app or
      // rotate its SharedWorker while a separate test server is running.
      ignored: [
        "**/.artifacts/**",
        "**/.tanstack/**",
        "**/artifacts/**",
        "**/coverage/**",
        "**/dist-electron/**",
      ],
    },
  },
})
