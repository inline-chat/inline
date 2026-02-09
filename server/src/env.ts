import { Log } from "@in/server/utils/log"

export const NODE_ENV = process.env.NODE_ENV ?? "development"
export const isProd = NODE_ENV === "production"
export const isDev = NODE_ENV === "development"
export const isTest = NODE_ENV === "test"

export const PORT = Number(process.env["PORT"] ?? 8000)
export const API_BASE_URL = isProd ? "https://api.inline.chat" : `http://localhost:${PORT}`

export const EMAIL_PROVIDER: "SES" | "RESEND" = process.env["EMAIL_PROVIDER"] === "SES" ? "SES" : "RESEND"
export const SEND_EMAIL = process.env["SEND_EMAIL"]

const rawDatabaseUrl = process.env["DATABASE_URL"]
const rawTestDatabaseUrl = process.env["TEST_DATABASE_URL"]

const ensureLocalDatabaseUrl = (databaseUrl: string): string => {
  let parsed: URL
  try {
    parsed = new URL(databaseUrl)
  } catch {
    throw new Error("Database URL must be a valid URL.")
  }

  const host = parsed.hostname
  if (host !== "localhost" && host !== "127.0.0.1") {
    throw new Error(`Refusing to use database URL with non-local host '${host}'.`)
  }

  return databaseUrl
}

export const DATABASE_URL = (() => {
  if (isProd) {
    return rawDatabaseUrl
  }

  if (isTest) {
    // Tests must never run against remote DBs. Prefer TEST_DATABASE_URL when present,
    // otherwise fall back to DATABASE_URL (so local dev doesn't need extra env for tests).
    const baseUrl = rawTestDatabaseUrl ?? rawDatabaseUrl
    if (!baseUrl) {
      throw new Error("DATABASE_URL (or TEST_DATABASE_URL) is required when NODE_ENV=test.")
    }
    return ensureLocalDatabaseUrl(baseUrl)
  }

  // Non-test environments should never accidentally use TEST_DATABASE_URL.
  if (!rawDatabaseUrl) {
    throw new Error("DATABASE_URL is required when NODE_ENV is not test/production.")
  }
  return rawDatabaseUrl
})() as string

// REQUIRED FOR PROD
export const AMAZON_ACCESS_KEY = process.env["AMAZON_ACCESS_KEY"] as string
export const AMAZON_SECRET_ACCESS_KEY = process.env["AMAZON_SECRET_ACCESS_KEY"] as string
export const TWILIO_AUTH_TOKEN = process.env["TWILIO_AUTH_TOKEN"] as string
export const TWILIO_SID = process.env["TWILIO_SID"] as string
export const TWILIO_VERIFY_SERVICE_SID = process.env["TWILIO_VERIFY_SERVICE_SID"] as string
export const SENTRY_DSN = process.env["SENTRY_DSN"] as string
export const RESEND_API_KEY = process.env["RESEND_API_KEY"] as string

export const APN_KEY = process.env["APN_KEY"] as string
export const APN_KEY_ID = process.env["APN_KEY_ID"] as string
export const APN_TEAM_ID = process.env["APN_TEAM_ID"] as string

export const R2_ACCESS_KEY_ID = process.env["R2_ACCESS_KEY_ID"] as string
export const R2_SECRET_ACCESS_KEY = process.env["R2_SECRET_ACCESS_KEY"] as string
export const R2_BUCKET = process.env["R2_BUCKET"] as string
export const R2_ENDPOINT = process.env["R2_ENDPOINT"] as string

export const PRELUDE_API_TOKEN = process.env["PRELUDE_API_TOKEN"] as string

// OPTIONAL
export const IPINFO_TOKEN = process.env["IPINFO_TOKEN"]
export const OPENAI_API_KEY = process.env["OPENAI_API_KEY"]
export const ANTHROPIC_API_KEY = process.env["ANTHROPIC_API_KEY"]
export const TELEGRAM_TOKEN = process.env["TELEGRAM_TOKEN"]
export const TELEGRAM_ALERTS_CHAT_ID = process.env["TELEGRAM_ALERTS_CHAT_ID"]
export const INLINE_ALERTS_BOT_TOKEN = process.env["INLINE_ALERTS_BOT_TOKEN"]
export const INLINE_ALERTS_CHAT_ID = process.env["INLINE_ALERTS_CHAT_ID"]
export const ADMIN_PUBLIC_API_ORIGIN = process.env["ADMIN_PUBLIC_API_ORIGIN"]
export const DEMO_EMAIL = process.env["DEMO_EMAIL"]
export const DEMO_CODE = process.env["DEMO_CODE"]

export const LINEAR_CLIENT_ID = process.env["LINEAR_CLIENT_ID"]
export const LINEAR_CLIENT_SECRET = process.env["LINEAR_CLIENT_SECRET"]
export const HARDCODED_TRANSLATION_CONTEXT = process.env["HARDCODED_TRANSLATION_CONTEXT"]

export const NOTION_CLIENT_ID = process.env["NOTION_CLIENT_ID"]
export const NOTION_CLIENT_SECRET = process.env["NOTION_CLIENT_SECRET"]

export const NOTION_CLIENT_ID_DEV = process.env["NOTION_CLIENT_ID_DEV"]
export const NOTION_CLIENT_SECRET_DEV = process.env["NOTION_CLIENT_SECRET_DEV"]

// Check required variables
const requiredProductionVariables = [
  "DATABASE_URL",
  "AMAZON_ACCESS_KEY",
  "AMAZON_SECRET_ACCESS_KEY",
  "TWILIO_SID",
  "TWILIO_VERIFY_SERVICE_SID",
  "SENTRY_DSN",
  "RESEND_API_KEY",
  "APN_KEY",
  "APN_KEY_ID",
  "APN_TEAM_ID",
  "R2_ACCESS_KEY_ID",
  "R2_SECRET_ACCESS_KEY",
  "R2_BUCKET",
  "R2_ENDPOINT",
  "PRELUDE_API_TOKEN",
]

for (const variable of requiredProductionVariables) {
  if (!process.env[variable]) {
    if (isProd) {
      throw new Error(`Required production variable ${variable} is not defined.`)
    } else if (!isTest) {
      Log.shared.warn(`Env variable ${variable} is not defined.`)
    }
  }
}

// Check optional variables
const optionalVariables = [
  "TWILIO_AUTH_TOKEN",
  "TWILIO_SID",
  "TWILIO_VERIFY_SERVICE_SID",
  "SENTRY_DSN",
  "IPINFO_TOKEN",
  "OPENAI_API_KEY",
  "ANTHROPIC_API_KEY",
  "TELEGRAM_TOKEN",
  "TELEGRAM_ALERTS_CHAT_ID",
  "INLINE_ALERTS_BOT_TOKEN",
  "INLINE_ALERTS_CHAT_ID",
  "LINEAR_CLIENT_ID",
  "LINEAR_CLIENT_SECRET",
  "HARDCODED_TRANSLATION_CONTEXT",
  "NOTION_CLIENT_ID",
  "NOTION_CLIENT_SECRET",
]

optionalVariables.forEach((variable) => {
  if (!process.env[variable] && isProd) {
    Log.shared.warn(`${variable} env variable is not defined.`)
  }
})
