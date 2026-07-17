import Elysia from "elysia"
import { InlineError } from "@in/server/types/errors"
import { Log } from "@in/server/utils/log"
import { recordApiError } from "@in/server/utils/metrics"

export const handleError = new Elysia({
  name: "api-error-handler",
})
  .error("INLINE_ERROR", InlineError)
  .onError(
    { as: "scoped" },
    ({ code, error, path, request, set, store }) => {
      recordApiError()
      const meta = getErrorMeta({
        request,
        path,
        store,
      })
      if (code === "NOT_FOUND") {
        set.status = 404
        Log.shared.error(
          "API ERROR NOT FOUND",
          error,
          { ...meta, status: 404 },
        )
        return {
          ok: false,
          error: "NOT_FOUND",
          errorCode: 404,
          description: "Method not found",
        }
      } else if (error instanceof InlineError) {
        set.status = error.code
        Log.shared.error("API ERROR", error, {
          ...meta,
          errorType: error.type,
          status: error.code,
        })
        return {
          ok: false,
          error: error.type,
          errorCode: error.code,
          description: error.description,
        }
      } else if (code === "VALIDATION") {
        set.status = 400
        Log.shared.error(
          "VALIDATION ERROR",
          error,
          { ...meta, status: 400 },
        )
        return {
          ok: false,
          error: "INVALID_ARGS",
          errorCode: 400,
          description: "Validation error",
        }
      } else {
        set.status = 500
        Log.shared.error(
          `Top level error ${code}`,
          error,
          { ...meta, status: 500 },
        )
        return {
          ok: false,
          error: "SERVER_ERROR",
          errorCode: 500,
          description: "Server error",
        }
      }
    },
  )

const getErrorMeta = ({
  request,
  path,
  store,
}: {
  request: Request
  path: string
  store: unknown
}) => {
  const state = store as {
    requestId?: unknown
    currentUserId?: unknown
    currentSessionId?: unknown
  }

  return {
    method: request.method,
    path,
    requestId:
      typeof state.requestId === "string"
        ? state.requestId
        : undefined,
    currentUserId:
      typeof state.currentUserId === "number"
        ? state.currentUserId
        : undefined,
    currentSessionId:
      typeof state.currentSessionId === "number"
        ? state.currentSessionId
        : undefined,
  }
}
