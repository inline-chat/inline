import { defineConfig } from "vite"
import path from "node:path"
import react from "@vitejs/plugin-react"
import tailwindcss from "@tailwindcss/vite"
import { tanstackRouter } from "@tanstack/router-plugin/vite"

export default defineConfig({
  plugins: [tanstackRouter({ target: "react" }), tailwindcss(), react()],
  css: {
    postcss: "./postcss.config.cjs",
  },
  resolve: {
    alias: {
      "@": path.resolve(__dirname, "src"),
    },
  },
  server: {
    port: 5174,
    strictPort: true,
    proxy: {
      "/admin": "http://localhost:8000",
    },
  },
})
