import { defineConfig } from "vitest/config"
import { aliases } from "./vite.config"
export default defineConfig({
  envDir: false,
  resolve: { alias: aliases },
  test: { include: ["src/**/*.test.ts", "src/**/*.test.tsx"] },
})
