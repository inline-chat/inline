import { Elysia } from "elysia"
import { setup } from "@in/server/setup"
import { gitCommitHash, relativeBuildDate, version } from "@in/server/env"

export const root = new Elysia()
  .use(setup)
  .get(
    "/",
    () =>
      `🚧 inline server is running • /** version: ${version} • deploy time: ${relativeBuildDate()} • commit: ${gitCommitHash} */`,
  )
