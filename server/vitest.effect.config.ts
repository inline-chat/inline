import { defineConfig } from "vitest/config"

export default defineConfig({
  test: {
    include: ["src/effect-server/**/*.effect.ts"],
    passWithNoTests: false,
    testTimeout: 10_000,
  },
})
