import { Elysia } from "elysia"
import { setup } from "@in/server/setup"
import { gitCommitHash, relativeBuildDate, version } from "@in/server/buildEnv"
import { html } from "@elysiajs/html"
import { renderRootPage } from "./rootPage"

export const root = new Elysia({ name: "root", prefix: "/" })
  .use(setup)
  // NOTE(@mo): This plugin breaks the error handling ref: https://github.com/elysiajs/elysia/issues/747
  // Kept isolated to this root controller so it doesn't affect API routes.
  .use(html())
  // DO NOT MODIFY THIS INITIAL PART OF MESSAGE
  // THIS IS MATCHED IN UPTIME MONITOR
  .get("/", () =>
    renderRootPage({
      gitCommitHash,
      relativeBuildDate: relativeBuildDate(),
      version,
    }),
  )
