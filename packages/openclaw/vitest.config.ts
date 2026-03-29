import path from "node:path"
import { defineConfig } from "vitest/config"

export default defineConfig({
  resolve: {
    alias: {
      // During monorepo dev/tests, resolve SDK/protocol types from source.
      "@inline-chat/realtime-sdk": path.resolve(__dirname, "../sdk/src"),
      "@inline-chat/protocol": path.resolve(__dirname, "../protocol/src"),
    },
  },
  test: {
    environment: "node",
    testTimeout: 15_000,
    include: ["src/index.test.ts", "src/runtime.test.ts", "src/manifest.test.ts", "src/inline/**/*.test.ts"],
    coverage: {
      provider: "v8",
      reporter: ["text"],
      all: false,
      include: ["src/index.ts", "src/runtime.ts", "src/inline/**/*.ts"],
      exclude: ["src/**/*.test.ts"],
      thresholds: {
        // This package is primarily integration code; unit tests cover the key pure helpers
        // and the outbound adapter. More coverage can be added as the monitor stabilizes.
        lines: 50,
        functions: 30,
        statements: 50,
        branches: 25,
      },
    },
  },
})
