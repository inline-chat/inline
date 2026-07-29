import { describe, expect, it } from "bun:test"

type EnvOverrides = Record<string, string | null>

const textDecoder = new TextDecoder()

const runBunSnippet = (script: string, overrides: EnvOverrides = {}) => {
  const env = { ...process.env } as Record<string, string>
  for (const [key, value] of Object.entries(overrides)) {
    if (value === null) {
      delete env[key]
      continue
    }
    env[key] = value
  }

  const result = Bun.spawnSync({
    cmd: ["bun", "-e", script],
    cwd: process.cwd(),
    env,
  })

  return {
    exitCode: result.exitCode,
    stdout: textDecoder.decode(result.stdout),
    stderr: textDecoder.decode(result.stderr),
  }
}

describe("startup and config guards", () => {
  it("fails env import in test mode when DATABASE_URL and TEST_DATABASE_URL are absent", () => {
    const result = runBunSnippet(
      `
      process.env.NODE_ENV = "test";
      delete process.env.DATABASE_URL;
      delete process.env.TEST_DATABASE_URL;
      import("./src/env.ts")
        .then(() => process.exit(0))
        .catch((error) => {
          console.error(error instanceof Error ? error.message : String(error));
          process.exit(1);
        });
      `,
    )

    expect(result.exitCode).toBe(1)
    expect(result.stderr).toContain("DATABASE_URL (or TEST_DATABASE_URL) is required when NODE_ENV=test.")
  })

  it("fails env import in test mode for non-local database host", () => {
    const result = runBunSnippet(
      `
      process.env.NODE_ENV = "test";
      process.env.TEST_DATABASE_URL = "postgres://user:pass@db.example.com:5432/app";
      import("./src/env.ts")
        .then(() => process.exit(0))
        .catch((error) => {
          console.error(error instanceof Error ? error.message : String(error));
          process.exit(1);
        });
      `,
    )

    expect(result.exitCode).toBe(1)
    expect(result.stderr).toContain("Refusing to use database URL with non-local host 'db.example.com'.")
  })

  it("fails env import in production when required variables are missing", () => {
    const result = runBunSnippet(
      `
      process.env.NODE_ENV = "production";
      delete process.env.DATABASE_URL;
      import("./src/env.ts")
        .then(() => process.exit(0))
        .catch((error) => {
          console.error(error instanceof Error ? error.message : String(error));
          process.exit(1);
        });
      `,
    )

    expect(result.exitCode).toBe(1)
    expect(result.stderr).toContain("Required production variable DATABASE_URL is not defined.")
  })

  it("warns without exposing values when the selected LiveKit triplet falls back to legacy variables", () => {
    const result = runBunSnippet(`
      process.env.NODE_ENV = "development";
      process.env.DATABASE_URL = "postgres://localhost:5432/dev";
      process.env.LIVEKIT_PROVIDER = "self_hosted";
      delete process.env.LIVEKIT_SELF_HOSTED_URL;
      delete process.env.LIVEKIT_SELF_HOSTED_API_KEY;
      delete process.env.LIVEKIT_SELF_HOSTED_API_SECRET;
      process.env.LIVEKIT_URL = "wss://legacy.example";
      process.env.LIVEKIT_API_KEY = "synthetic-key";
      process.env.LIVEKIT_API_SECRET = "synthetic-secret";
      import("./src/env.ts")
        .then(() => process.exit(0))
        .catch(() => process.exit(1));
    `)

    const output = `${result.stdout}\n${result.stderr}`
    expect(result.exitCode).toBe(0)
    expect(output).toContain("falling back to legacy LIVEKIT_URL, LIVEKIT_API_KEY, and LIVEKIT_API_SECRET")
    expect(output).not.toContain("synthetic-key")
    expect(output).not.toContain("synthetic-secret")
  })

  it("fails test DB setup when neither TEST_DATABASE_URL nor DATABASE_URL are available at call time", () => {
    const result = runBunSnippet(
      `
      process.env.NODE_ENV = "development";
      process.env.DATABASE_URL = "postgres://localhost:5432/dev";
      (async () => {
        const { setupTestDatabase } = await import("./src/__tests__/setup.ts");
        delete process.env.DATABASE_URL;
        delete process.env.TEST_DATABASE_URL;
        try {
          await setupTestDatabase();
          process.exit(0);
        } catch (error) {
          console.error(error instanceof Error ? error.message : String(error));
          process.exit(1);
        }
      })();
      `,
    )

    expect(result.exitCode).toBe(1)
    expect(result.stderr).toContain("TEST_DATABASE_URL (or DATABASE_URL) is required to run DB tests")
  })

  it("fails test DB setup when TEST_DATABASE_URL points to a non-local host", () => {
    const result = runBunSnippet(
      `
      process.env.NODE_ENV = "development";
      process.env.DATABASE_URL = "postgres://localhost:5432/dev";
      process.env.TEST_DATABASE_URL = "postgres://user:pass@db.example.com:5432/app";
      (async () => {
        const { setupTestDatabase } = await import("./src/__tests__/setup.ts");
        try {
          await setupTestDatabase();
          process.exit(0);
        } catch (error) {
          console.error(error instanceof Error ? error.message : String(error));
          process.exit(1);
        }
      })();
      `,
    )

    expect(result.exitCode).toBe(1)
    expect(result.stderr).toContain("Refusing to run DB tests against non-local host 'db.example.com'.")
  })
})
