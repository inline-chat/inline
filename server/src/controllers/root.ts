import { Elysia } from "elysia"
import { setup } from "@in/server/setup"
import { version } from "../../package.json"

export const root = new Elysia().use(setup).get("/", () => `🚧 Inline server running 🚧 ${version}`)
