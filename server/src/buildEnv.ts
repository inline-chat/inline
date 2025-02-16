import { $ } from "bun"

const isProd = process.env.NODE_ENV === "production"

// Build time variables
export const version = process.env.VERSION || (!isProd ? (await import("../package.json")).version : "N/A")
export const gitCommitHash = process.env.GIT_COMMIT_HASH
  ? process.env.GIT_COMMIT_HASH.trim().slice(0, 7)
  : !isProd
  ? (await $`git rev-parse HEAD`.text()).trim().slice(0, 7)
  : "N/A"
export const buildDate = process.env.BUILD_DATE || new Date().toISOString()
export const relativeBuildDate = () => {
  const date = new Date(buildDate)
  const diff = new Date().getTime() - date.getTime()

  const seconds = Math.floor(diff / 1000) % 60
  const minutes = Math.floor(diff / (1000 * 60)) % 60
  const hours = Math.floor(diff / (1000 * 60 * 60)) % 24
  const days = Math.floor(diff / (1000 * 60 * 60 * 24))

  const parts = []
  if (days > 0) parts.push(`${days}d`)
  if (hours > 0) parts.push(`${hours}h`)
  if (minutes > 0) parts.push(`${minutes}m`)
  if (seconds > 0) parts.push(`${seconds}s`)

  return parts.length > 0 ? `${parts.join(" ")} ago` : "just now"
}

declare global {
  namespace NodeJS {
    interface ProcessEnv {
      NODE_ENV: "development" | "production" | "test"
      VERSION?: string
      GIT_COMMIT_HASH?: string
      BUILD_DATE?: string
      DATABASE_URL: string
      AMAZON_ACCESS_KEY: string
      AMAZON_SECRET_ACCESS_KEY: string
      TWILIO_AUTH_TOKEN?: string
      TWILIO_SID: string
      TWILIO_VERIFY_SERVICE_SID: string
      SENTRY_DSN: string
      RESEND_API_KEY: string
      IPINFO_TOKEN?: string
      LINEAR_CLIENT_ID?: string
      LINEAR_CLIENT_SECRET?: string
      LINEAR_REDIRECT_URI?: string
      OPENAI_API_KEY?: string
      OPENAI_BASE_URL?: string
      // Allow for additional dynamic environment variables
      [key: string]: string | undefined
    }
  }
}
