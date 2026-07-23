import { defineConfig } from "vitest/config"

export default defineConfig({
  resolve: {
    alias: {
      "~": new URL("./src", import.meta.url).pathname,
    },
  },
  test: {
    // Keep protocol-deadline and browser-storage tests deterministic on
    // high-core-count developer/CI machines. Unbounded file workers can
    // starve MessagePort microtasks long enough to manufacture timeouts.
    maxWorkers: 4,
    environment: "jsdom",
    environmentOptions: {
      jsdom: {
        url: "http://inline.test",
      },
    },
    include: ["src/**/*.test.ts", "src/**/*.test.tsx"],
    setupFiles: ["./src/testing/setup.ts"],
  },
})
