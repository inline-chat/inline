import { Log } from "@in/server/utils/log"

export const isProd = process.env.NODE_ENV === "production"

// REQUIRED FOR DEV AND PROD
export const DATABASE_URL = process.env["DATABASE_URL"] as string

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

export const LINEAR_CLIENT_ID = process.env["LINEAR_CLIENT_ID"]
export const LINEAR_CLIENT_SECRET = process.env["LINEAR_CLIENT_SECRET"]
export const WANVER_TRANSLATION_CONTEXT = process.env["WANVER_TRANSLATION_CONTEXT"]

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
    } else {
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
  "LINEAR_CLIENT_ID",
  "LINEAR_CLIENT_SECRET",
  "WANVER_TRANSLATION_CONTEXT",
  "NOTION_CLIENT_ID",
  "NOTION_CLIENT_SECRET",
]

optionalVariables.forEach((variable) => {
  if (!process.env[variable] && isProd) {
    Log.shared.warn(`${variable} env variable is not defined.`)
  }
})
