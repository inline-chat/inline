import { Elysia } from "elysia"
import { setup } from "@in/server/setup"

export const root = new Elysia()
  .use(setup)
  .get("/", () => "🚧 Inline server running 🚧")
