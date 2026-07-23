import { defineConfig, devices } from "@playwright/test"

const port = 18_101
const origin = `http://127.0.0.1:${port}`

export default defineConfig({
  testDir: "./tests/browser/specs",
  testMatch: "**/*.pw.ts",
  outputDir: ".artifacts/playwright",
  fullyParallel: false,
  workers: 1,
  retries: 0,
  reporter: "line",
  use: {
    ...devices["Desktop Chrome"],
    baseURL: origin,
    channel: "chrome",
    trace: "retain-on-failure",
  },
  webServer: {
    command: `./node_modules/.bin/vite dev --host 127.0.0.1 --port ${port} --strictPort`,
    url: origin,
    reuseExistingServer: false,
    timeout: 30_000,
    gracefulShutdown: {
      signal: "SIGTERM",
      timeout: 2_000,
    },
    stdout: "ignore",
    stderr: "pipe",
  },
})
