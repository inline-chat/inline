import { defineConfig } from "vitest/config"

/**
 * The tooling's own tests (`web/vitest.config.ts` includes `src` only):
 *   bunx vitest run -c tooling/measure-vitest.config.ts
 */
export default defineConfig({
  root: new URL("..", import.meta.url).pathname,
  test: {
    environment: "node",
    include: ["tooling/**/*.test.ts"],
  },
})
