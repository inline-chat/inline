import { isProd } from "@in/server/env"
import { $ } from "bun"

// Build time variables
export const version = process.env.VERSION || (!isProd ? (await import("../package.json")).version : "N/A")
export const gitCommitHash = process.env.GIT_COMMIT_HASH || "N/A"
// || (!isProd ? (await $`git rev-parse HEAD`.text()).trim().slice(0, 7) : "N/A")
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
