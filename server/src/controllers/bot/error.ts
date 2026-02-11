import Elysia from "elysia"
import { InlineError } from "@in/server/types/errors"
import { Log } from "@in/server/utils/log"
import { recordApiError } from "@in/server/utils/metrics"

// Bot API uses a compact HTTP error envelope: { ok: false, error_code, description }.
export const handleBotError = new Elysia({ name: "bot-api-error-handler" })
  .error("INLINE_ERROR", InlineError)
  .onError({ as: "scoped" }, ({ code, error, path, set }) => {
    recordApiError()

    if (code === "NOT_FOUND") {
      Log.shared.error("BOT API NOT FOUND", error)
      set.status = 404
      return {
        ok: false,
        error: "NOT_FOUND",
        error_code: 404,
        description: "Method not found",
      }
    }

    if (error instanceof InlineError) {
      Log.shared.error("BOT API ERROR", error)
      set.status = error.code
      return {
        ok: false,
        error: error.type,
        error_code: error.code,
        description: error.description,
      }
    }

    if (code === "VALIDATION") {
      Log.shared.error("BOT API VALIDATION ERROR", error)
      set.status = 400
      return {
        ok: false,
        error: "INVALID_ARGS",
        error_code: 400,
        description: "Validation error",
      }
    }

    Log.shared.error(`Bot API top level error ${code} in ${path}`, error)
    set.status = 500
    return {
      ok: false,
      error: "SERVER_ERROR",
      error_code: 500,
      description: "Server error",
    }
  })
