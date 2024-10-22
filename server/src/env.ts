export const isProd = process.env.NODE_ENV === "production"

export const DATABASE_URL = process.env["DATABASE_URL"] as string
export const TWILIO_AUTH_TOKEN = process.env["TWILIO_AUTH_TOKEN"] as string
export const TWILIO_SID = process.env["TWILIO_SID"] as string
export const TWILIO_VERIFY_SERVICE_SID = process.env["TWILIO_VERIFY_SERVICE_SID"] as string
export const SENTRY_DSN = process.env["SENTRY_DSN"] as string
export const AMAZON_ACCESS_KEY = process.env["AMAZON_ACCESS_KEY"] as string
export const AMAZON_SECRET_ACCESS_KEY = process.env["AMAZON_SECRET_ACCESS_KEY"] as string

// Check required variables

const requiredProductionVariables = ["DATABASE_URL", "AMAZON_ACCESS_KEY", "AMAZON_SECRET_ACCESS_KEY"]

if (requiredProductionVariables.some((variable) => !process.env[variable])) {
  if (process.env.NODE_ENV === "production") {
    throw new Error("Required production variables must be defined.")
  } else {
    console.warn("Some env variables are not defined")
  }
}

// Check optional variables
const optionalVariables = ["TWILIO_AUTH_TOKEN", "TWILIO_SID", "TWILIO_VERIFY_SERVICE_SID", "SENTRY_DSN"]

optionalVariables.forEach((variable) => {
  if (!process.env[variable]) {
    console.warn(`${variable} env variable is not defined.`)
  }
})
