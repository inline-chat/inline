import path from "node:path"
import { defineConfig } from "vitest/config"

export default defineConfig({
  resolve: {
    alias: {
      "@inline-chat/protocol": path.resolve(__dirname, "../../../packages/protocol/src"),
      "@inline/log": path.resolve(__dirname, "../../../landing/packages/log/src/index.ts"),
      "@inline/config": path.resolve(__dirname, "../../../landing/packages/config/src/index.ts"),
    },
  },
  test: {
    include: ["src/**/*.test.ts", "src/**/*.test.tsx"],
  },
})
