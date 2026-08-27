import { defineConfig } from "vitest/config"
import { fileURLToPath } from "node:url"

export default defineConfig({
  resolve: {
    alias: {
      "@in/server": fileURLToPath(new URL("./src", import.meta.url)),
    },
  },
  test: {
    env: {
      // Some production encoders validate the test database URL at import time.
      // Effect tests do not connect to this deliberately nonexistent database.
      TEST_DATABASE_URL: "postgres://localhost:5432/inline_effect_test",
      // Match the non-secret placeholder from the Bun test preload for modules
      // that construct the Resend client while the encoder graph is imported.
      RESEND_API_KEY: "test-key",
    },
    exclude: [
      "src/**/*.effect.bun.test.ts",
      "src/core/http/realtimeV3Host.test.ts",
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
    testTimeout: 30_000,
  },
})
