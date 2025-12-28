import path from "node:path"
import { defineConfig } from "vitest/config"

export default defineConfig({
  resolve: {
    alias: {
      "@in/protocol": path.resolve(__dirname, "../protocol/src"),
      "@inline/log": path.resolve(__dirname, "../log/src/index.ts"),
      "@inline/config": path.resolve(__dirname, "../config/src/index.ts"),
    },
  },
  test: {
    include: ["src/**/*.test.ts", "src/**/*.test.tsx"],
  },
})
