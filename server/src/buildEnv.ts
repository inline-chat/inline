import { $ } from "bun"

const isProd = process.env.NODE_ENV === "production"

// Build time variables
export const version = process.env.VERSION || (!isProd ? (await import("../package.json")).version : "N/A")
export const gitCommitHash =
  process.env.GIT_COMMIT_HASH || (!isProd ? (await $`git rev-parse HEAD`.text()).trim().slice(0, 7) : "N/A")
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
