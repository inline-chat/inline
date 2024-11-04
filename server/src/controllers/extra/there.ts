import { Elysia, t } from "elysia"
import { setup } from "@in/server/setup"
import { insertThereUser } from "../../db/models/there"

export const there = new Elysia({ prefix: "/api/there" }).use(setup).post(
  "/signup",
  async ({ body }) => {
    await insertThereUser(body)

    return {
      ok: true,
    }
  },
  {
    body: t.Object({
      email: t.String(),
      name: t.Optional(t.String()),
      timeZone: t.Optional(t.String()),
    }),
  },
)
