export const DATABASE_URL = process.env.DATABASE_URL as string

// Twilio
export const TWILIO_AUTH_TOKEN = process.env.TWILIO_AUTH_TOKEN as string
export const TWILIO_SID = process.env.TWILIO_SID as string
export const TWILIO_VERIFY_SERVICE_SID = process.env
  .TWILIO_VERIFY_SERVICE_SID as string

// Sentry
export const SENTRY_DSN = process.env.SENTRY_DSN as string

// Check required variables
if (!DATABASE_URL) {
  throw new Error("DATABASE_URL env variable must be defined.")
}

// Check optional variables
const optionalVariables = [
  "TWILIO_AUTH_TOKEN",
  "TWILIO_SID",
  "TWILIO_VERIFY_SERVICE_SID",
  "SENTRY_DSN",
]

optionalVariables.forEach((variable) => {
  if (!process.env[variable]) {
    console.warn(`${variable} env variable is not defined.`)
  }
})
