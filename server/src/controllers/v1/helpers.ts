import { authenticate, authenticateGet } from "@in/server/controllers/plugins"
import { ErrorCodes, InlineError } from "@in/server/types/errors"
import { Log } from "@in/server/utils/log"
import Elysia, { t, type TSchema, type Static, type TDecodeType, type InputSchema } from "elysia"
import type { TUndefined, TObject } from "@sinclair/typebox"

export const TMakeApiResponse = <T extends TSchema>(type: T) => {
  const success = t.Object({ ok: t.Literal(true), result: type })
  const failure = t.Object({
    ok: t.Literal(false),
    errorCode: t.Optional(t.Number()),
    description: t.Optional(t.String()),
  })

  return t.Union([success, failure])
}

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

export type HandlerContext = {
  currentUserId: number
}

export type UnauthenticatedHandlerContext = {}

export const makeApiRoute = <Path extends string, ISchema extends TObject, OSchema extends TSchema>(
  path: Path,
  inputType: ISchema | TUndefined,
  outputType: OSchema,
  method: (input: any, context: HandlerContext) => Promise<TDecodeType<OSchema>>,
) => {
  const response = TMakeApiResponse(outputType)
  const getRoute = new Elysia({ tags: ["GET"] }).use(authenticateGet).get(
    `/:token?${path}`,
    async ({ query: input, store }) => {
      const context = { currentUserId: store.currentUserId }
      let result = await method(input, context)
      return { ok: true, result } as any
    },
    {
      query: inputType,
      response: response,
    },
  )

  const postRoute = new Elysia({ tags: ["POST"] }).use(authenticate).post(
    path,
    async ({ body: input, store }) => {
      const context = { currentUserId: store.currentUserId }
      let result = await method(input, context)
      return { ok: true, result } as any
    },
    {
      body: inputType,
      response: response,
    },
  )

  return new Elysia().use(getRoute).use(postRoute)
}

export const makeUnauthApiRoute = <Path extends string, ISchema extends TObject, OSchema extends TSchema>(
  path: Path,
  inputType: ISchema,
  outputType: OSchema,
  method: (input: any, context: UnauthenticatedHandlerContext) => Promise<TDecodeType<OSchema>>,
) => {
  const response = TMakeApiResponse(outputType)
  const getRoute = new Elysia({ tags: ["GET"] }).get(
    `${path}`,
    async ({ query: input }) => {
      let result = await method(input, {})
      return { ok: true, result } as any
    },
    {
      query: inputType,
      response: response,
    },
  )

  const postRoute = new Elysia({ tags: ["POST"] }).post(
    path,
    async ({ body: input }) => {
      let result = await method(input, {})
      return { ok: true, result } as any
    },
    {
      body: inputType,
      response: response,
    },
  )

  return new Elysia().use(getRoute).use(postRoute)
}
