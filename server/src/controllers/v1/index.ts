import { Elysia } from "elysia"
import { setup } from "@in/server/setup"
import { getMeRoute } from "@in/server/controllers/v1/getMe"
import { sendEmailCodeRoute } from "@in/server/controllers/v1/sendEmailCode"
import { verifyEmailCodeRoute } from "@in/server/controllers/v1/verifyEmailCode"
import { handleError } from "@in/server/controllers/v1/helpers"

export const apiV1 = new Elysia({ name: "v1" })
  .group("v1/:token?", (app) => {
    return app
      .use(setup)
      .use(sendEmailCodeRoute)
      .use(verifyEmailCodeRoute)
      .use(getMeRoute)
      .all("/*", () => {
        // fallback
        return { ok: false, errorCode: 404, description: "Method not found" }
      })
  })
  .use(handleError)
