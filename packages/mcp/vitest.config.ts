import { configDefaults, defineConfig } from "vitest/config"

export default defineConfig({
  test: {
    environment: "node",
    include: ["src/**/*.test.ts"],
    exclude: [...configDefaults.exclude, "dist/**"],
    coverage: {
      provider: "v8",
      reporter: ["text", "html", "json-summary"],
      // Integration against Inline realtime WS. Covered indirectly at higher layers.
      exclude: ["src/**/*.test.ts", "src/server/inline/inline-api.ts", "dist/**"],
      // Keep this reasonably high while the package is under heavy construction.
      // Tighten back toward 100% once the endpoint surface stabilizes.
      thresholds: {
        lines: 95,
        functions: 95,
        statements: 90,
        branches: 80,
      },
    },
  },
})
