import { Elysia } from "elysia"
import { setup } from "@in/server/setup"
import { gitCommitHash, relativeBuildDate, version } from "@in/server/buildEnv"

export const root = new Elysia()
  .use(setup)
  // DO NOT MODIFY THIS INITIAL PART OF MESSAGE
  // THIS IS MATCHED IN UPTIME MONITOR
  .get("/", () => `🚧 inline server is running • v${version} • deployed ${relativeBuildDate()} • ${gitCommitHash}`)
