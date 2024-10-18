import { Elysia, t } from "elysia"
import { setup } from "@in/server/setup"
import { auth } from "@in/server/controllers/v001/auth"
import { createSpaceRoute } from "@in/server/controllers/v001/createSpace"
import { ErrorCodes, InlineError } from "@in/server/types/errors"
import { Log } from "@in/server/utils/log"
import { swagger } from "@elysiajs/swagger"

export const apiV001 = new Elysia({ name: "v001" })
  .group("v001", (app) => {
    return app
      .use(setup)
      .use(auth)
      .use(createSpaceRoute)
      .all("/*", () => {
        return { ok: false, errorCode: 404, description: "Method not found" }
      })
  })

  .error("INLINE_ERROR", InlineError)
  .onError(({ code, error }) => {
    if (code === "NOT_FOUND")
      return {
        ok: false,
        errorCode: 404,
        description: "Method not found",
      }
    if (error instanceof InlineError) {
      return {
        ok: false,
        errorCode: error.code,
        description: error.message,
      }
    } else if (code === "VALIDATION") {
      return {
        ok: false,
        errorCode: ErrorCodes.INAVLID_ARGS,
        description: "Validation error",
      }
    } else {
      Log.shared.error("Top level error, " + code, error)
      return {
        ok: false,
        errorCode: ErrorCodes.SERVER_ERROR,
        description: "Server error",
      }
    }
  })
