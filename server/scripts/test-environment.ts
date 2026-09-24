// Deliberately inherit only runtime settings, never developer service credentials
// or rollout flags. Tests set application configuration explicitly per scenario.
const runtimeVariables = [
  "PATH", "HOME", "USER", "LOGNAME", "SHELL", "TMPDIR", "TMP", "TEMP",
  "SystemRoot", "CI", "GITHUB_ACTIONS", "TERM", "NO_COLOR", "FORCE_COLOR",
  "BUN_TEST_WORKER_ID", "JEST_WORKER_ID",
] as const

export const testDefaults = {
  NODE_ENV: "test",
  TZ: "UTC",
  RESEND_API_KEY: "test-key",
  ENCRYPTION_KEY: "1234567890123456789012345678901212345678901234567890123456789012",
  AMAZON_ACCESS_KEY: "test-key",
  AMAZON_SECRET_ACCESS_KEY: "test-secret",
  SES_ACCESS_KEY_ID: "test-key",
  SES_SECRET_ACCESS_KEY: "test-secret",
  OPENAI_API_KEY: "test-key",
  ANTHROPIC_API_KEY: "test-key",
  SENTRY_DSN: "",
} as const

export function createTestEnvironment(
  inherited: Record<string, string | undefined>,
  databaseUrl = "postgres://localhost:1/inline_unit_test",
): Record<string, string> {
  const environment: Record<string, string> = { ...testDefaults }
  for (const key of runtimeVariables) {
    if (inherited[key] !== undefined) environment[key] = inherited[key]
  }
  environment["DATABASE_URL"] = databaseUrl
  environment["TEST_DATABASE_URL"] = databaseUrl
  const redisUrl = inherited["INLINE_TEST_REDIS_URL"]
  if (redisUrl) {
    const parsed = new URL(redisUrl)
    if (parsed.protocol !== "redis:" || !["localhost", "127.0.0.1", "[::1]"].includes(parsed.hostname) ||
        !parsed.port || parsed.username || parsed.password || !["", "/"].includes(parsed.pathname)) {
      throw new Error("INLINE_TEST_REDIS_URL must be an unauthenticated local Redis endpoint with an explicit port.")
    }
    environment["INLINE_TEST_REDIS_URL"] = redisUrl
    environment["REDIS_URL"] = redisUrl
  }
  return environment
}

export function applyTestDefaults(): void {
  Object.assign(process.env, testDefaults)
}
