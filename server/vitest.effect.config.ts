import { defineConfig } from "vitest/config"
import { fileURLToPath } from "node:url"

export default defineConfig({
  resolve: {
    alias: {
      "@in/server": fileURLToPath(new URL("./src", import.meta.url)),
    },
  },
  test: {
    exclude: [
      "src/**/*.effect.bun.test.ts",
    ],
    include: [
      "src/core/**/*.{test,spec}.ts",
      "src/**/*.effect.{test,spec}.ts",
    ],
    environment: "node",
    isolate: true,
    clearMocks: true,
    restoreMocks: true,
    unstubEnvs: true,
    unstubGlobals: true,
    fakeTimers: {
      // Effect's TestClock owns virtual time in Effect tests.
      toFake: undefined,
    },
    passWithNoTests: false,
    testTimeout: 10_000,
  },
})
