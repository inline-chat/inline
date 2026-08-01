export const DEV_ADMIN_EMAIL = "dev-admin@localhost.inline.chat"

const DEV_ADMIN_ORIGINS = new Set([
  "http://localhost:5174",
  "http://127.0.0.1:5174",
])

const isLoopbackIp = (ip: string | undefined): boolean =>
  ip === "127.0.0.1" ||
  ip === "::1" ||
  ip === "::ffff:127.0.0.1"

export const isDevAdminLoginAllowed = (input: {
  readonly nodeEnv: string | undefined
  readonly origin: string | undefined
  readonly ip: string | undefined
}): boolean =>
  input.nodeEnv === "development" &&
  DEV_ADMIN_ORIGINS.has(input.origin ?? "") &&
  isLoopbackIp(input.ip)
