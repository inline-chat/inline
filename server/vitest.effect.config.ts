import { defineConfig } from "vitest/config"
import { fileURLToPath } from "node:url"
import { effectVitestInclude } from "./scripts/test-discovery"
import { createTestEnvironment } from "./scripts/test-environment"

export default defineConfig({
  resolve: {
    alias: {
      "@in/server": fileURLToPath(new URL("./src", import.meta.url)),
    },
  },
  test: {
    env: createTestEnvironment(process.env),
    setupFiles: ["./src/__tests__/effect-setup.ts"],
    include: effectVitestInclude(fileURLToPath(new URL(".", import.meta.url))),
    environment: "node",
    isolate: true,
    maxWorkers: 4,
    allowOnly: false,
    reporters: process.env["CI"] ? ["default", "junit"] : ["default"],
    outputFile: { junit: ".test-results/effect.xml" },
    clearMocks: true,
    restoreMocks: true,
    unstubEnvs: true,
    unstubGlobals: true,
    fakeTimers: {
      // Effect's TestClock owns virtual time in Effect tests.
      toFake: undefined,
    },
    passWithNoTests: false,
    testTimeout: 30_000,
  },
})
