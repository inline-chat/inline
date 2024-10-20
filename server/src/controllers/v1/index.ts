import { Elysia } from "elysia"
import { setup } from "@in/server/setup"
import { getMeRoute } from "@in/server/controllers/v1/getMe"
import { sendEmailCodeRoute } from "@in/server/controllers/v1/sendEmailCode"
import { verifyEmailCodeRoute } from "@in/server/controllers/v1/verifyEmailCode"
import { handleError } from "@in/server/controllers/v1/helpers"
import { getSpacesRoute } from "@in/server/controllers/v1/getSpaces"
import { createSpaceRoute } from "@in/server/controllers/v1/createSpace"
import { updateProfileRoute } from "@in/server/controllers/v1/updateProfile"
import { checkUsernameRoute } from "./checkUsername"
import { getSpaceRoute } from "./getSpace"

export const apiV1 = new Elysia({ name: "v1" })
  .group("v1/:token?", (app) => {
    return app
      .use(setup)
      .use(createSpaceRoute)
      .use(sendEmailCodeRoute)
      .use(verifyEmailCodeRoute)
      .use(getMeRoute)
      .use(getSpacesRoute)
      .use(updateProfileRoute)
      .use(checkUsernameRoute)
      .use(getSpaceRoute)
      .all("/*", () => {
        // fallback
        return { ok: false, errorCode: 404, description: "Method not found" }
      })
  })
  .use(handleError)
