import { Elysia, t } from "elysia"
import { setup } from "@in/server/setup"
import { insertIntoWaitlist } from "@in/server/db/models/waitlist"

export const waitlist = new Elysia({ prefix: "/waitlist" })
  .use(setup)
  .post(
    "/subscribe",
    async ({ body }) => {
      await insertIntoWaitlist(body)

      // todo: send verification

      return {
        ok: true,
      }
    },
    {
      body: t.Object({
        email: t.String(),
        name: t.Optional(t.String()),
        userAgent: t.Optional(t.String()),
        timeZone: t.Optional(t.String()),
      }),
    },
  )
  .post("/verify", () => "todo")
