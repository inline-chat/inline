import path from "node:path"
import { mkdtempSync } from "node:fs"
import { tmpdir } from "node:os"
import { defineConfig } from "vitest/config"

const hostStateDir = mkdtempSync(path.join(tmpdir(), "inline-openclaw-test-state-"))

export default defineConfig({
  resolve: {
    alias: {
      ...(process.env.OPENCLAW_COMPAT_HOST_ROOT ? {
        "openclaw/plugin-sdk": path.join(process.env.OPENCLAW_COMPAT_HOST_ROOT, "dist", "plugin-sdk"),
      } : {}),
      // During monorepo dev/tests, resolve SDK/protocol types from source.
      "@inline-chat/realtime-sdk": path.resolve(__dirname, "../sdk/src"),
      "@inline-chat/protocol": path.resolve(__dirname, "../packages/protocol/src"),
    },
  },
  test: {
    environment: "node",
    env: {
      OPENCLAW_STATE_DIR: hostStateDir,
      OPENCLAW_CONFIG_PATH: path.join(hostStateDir, "openclaw.json"),
      OPENCLAW_AGENT_DIR: path.join(hostStateDir, "agents", "main", "agent"),
    },
    maxWorkers: 2,
    testTimeout: 90_000,
    include: ["src/**/*.test.ts"],
    coverage: {
      provider: "v8",
      reporter: ["text"],
      all: false,
      include: ["src/index.ts", "src/runtime.ts", "src/telemetry.ts", "src/inline/**/*.ts"],
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
