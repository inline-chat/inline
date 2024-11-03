import { $ } from "bun"

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

// OPTIONAL
export const IPINFO_TOKEN = process.env["IPINFO_TOKEN"]

// Check required variables
const requiredProductionVariables = [
  "DATABASE_URL",
  "AMAZON_ACCESS_KEY",
  "AMAZON_SECRET_ACCESS_KEY",
  "TWILIO_SID",
  "TWILIO_VERIFY_SERVICE_SID",
  "SENTRY_DSN",
  "RESEND_API_KEY",
]

for (const variable of requiredProductionVariables) {
  if (!process.env[variable]) {
    if (isProd) {
      throw new Error(`Required production variable ${variable} is not defined.`)
    } else {
      console.warn(`Env variable ${variable} is not defined.`)
    }
  }
}

// Check optional variables
const optionalVariables = ["TWILIO_AUTH_TOKEN", "TWILIO_SID", "TWILIO_VERIFY_SERVICE_SID", "SENTRY_DSN", "IPINFO_TOKEN"]

optionalVariables.forEach((variable) => {
  if (!process.env[variable] && isProd) {
    console.warn(`${variable} env variable is not defined.`)
  }
})

// Build time variables
export const version = process.env.VERSION || (await import("../package.json")).version
export const gitCommitHash = process.env.GIT_COMMIT_HASH || (await $`git rev-parse HEAD`.text()).trim().slice(0, 7)
export const buildDate = process.env.BUILD_DATE || new Date().toISOString()

export const relativeBuildDate = () => {
  let date = new Date(buildDate)
  let diff = new Date().getTime() - date.getTime()

  let seconds = Math.floor(diff / 1000) % 60
  let minutes = Math.floor(diff / (1000 * 60)) % 60
  let hours = Math.floor(diff / (1000 * 60 * 60)) % 24
  let days = Math.floor(diff / (1000 * 60 * 60 * 24))

  return `${days}d ${hours}h ${minutes}m ${seconds}s ago`
}
declare global {
  namespace NodeJS {
    interface ProcessEnv {
      BUILD_DATE: string
      GIT_COMMIT_HASH: string
      VERSION: string
    }
  }
}
