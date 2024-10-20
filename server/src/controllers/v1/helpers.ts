import { ErrorCodes, InlineError } from "@in/server/types/errors"
import Elysia, { t, TSchema } from "elysia"

export const TMakeApiResponse = <T extends TSchema>(type: T) =>
  t.Union([
    t.Composite([t.Object({ ok: t.Literal(true) }), type]),
    t.Object({
      ok: t.Literal(false),
      errorCode: t.Number(),
      description: t.Optional(t.String()),
    }),
  ])

export const handleError = new Elysia()
  .error("INLINE_ERROR", InlineError)
  .onError({ as: "scoped" }, ({ code, error }) => {
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
