import { fileURLToPath } from "node:url"
import { defineConfig } from "vite"
import react from "@vitejs/plugin-react"

const source = (path: string) => fileURLToPath(new URL(path, import.meta.url))
export const aliases = [
  { find: /^@inline\/client(?=\/|$)/, replacement: source("../landing/packages/client/src") },
  { find: /^@inline\/auth(?=\/|$)/, replacement: source("../landing/packages/auth/src") },
  { find: "@inline/ids", replacement: source("../landing/packages/ids/src/index.ts") },
  { find: "@inline/config", replacement: source("../landing/packages/config/src/index.ts") },
  { find: "@inline/log", replacement: source("../landing/packages/log/src/index.ts") },
  { find: /^@inline-chat\/protocol(?=\/|$)/, replacement: source("../packages/protocol/src") },
]

export default defineConfig(({ mode }) => ({
  // Configuration is explicit; this app never loads .env files.
  envDir: false,
  plugins: [react()],
  resolve: { alias: aliases, dedupe: ["react", "react-dom"] },
  define: {
    __INLINE_WEB_ENABLED__: JSON.stringify(mode === "experimental"),
    __INLINE_API_ORIGIN__: JSON.stringify(
      process.env.INLINE_WEB_API_ORIGIN ?? "https://api.inline.chat"
    ),
  },
  server: {
    host: "127.0.0.1",
    port: 8010,
    strictPort: true,
    proxy: {
      "/v1": {
        target: process.env.INLINE_WEB_API_ORIGIN ?? "https://api.inline.chat",
        changeOrigin: true,
      },
    },
  },
  preview: { host: "127.0.0.1", port: 8010, strictPort: true },
  build: { sourcemap: true },
}))
