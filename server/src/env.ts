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
]

if (requiredProductionVariables.some((variable) => !process.env[variable])) {
  if (process.env.NODE_ENV === "production") {
    throw new Error("Required production variables must be defined.")
  } else {
    console.warn("Some env variables are not defined")
  }
}

// Check optional variables
const optionalVariables = ["TWILIO_AUTH_TOKEN", "TWILIO_SID", "TWILIO_VERIFY_SERVICE_SID", "SENTRY_DSN", "IPINFO_TOKEN"]

optionalVariables.forEach((variable) => {
  if (!process.env[variable] && isProd) {
    console.warn(`${variable} env variable is not defined.`)
  }
})
