import { authenticate, authenticateGet } from "@in/server/controllers/plugins"
import { ApiError, ErrorCodes, InlineError } from "@in/server/types/errors"
import { Log } from "@in/server/utils/log"
import Elysia, { t, type TSchema, type Static, type InputSchema } from "elysia"
import { type TUndefined, type TObject, type TDecodeType, Type } from "@sinclair/typebox"
import { TOptional, TPeerInfo } from "@in/server/api-types"
import { normalizeId, TInputId } from "@in/server/types/methods"
import { measureTime } from "@in/server/utils/helpers/measure"

export const TMakeApiResponse = <T extends TSchema>(type: T) => {
  const success = t.Object({ ok: t.Literal(true), result: type })
  const failure = t.Object({
    ok: t.Literal(false),
    error: t.String(),
    errorCode: t.Optional(t.Number()),
    description: t.Optional(t.String()),
  })

  return t.Union([success, failure])
}

export const handleError = new Elysia({ name: "api-error-handler" })
  .error("INLINE_ERROR", InlineError)
  .onError({ as: "scoped" }, ({ code, error, path }) => {
    if (code === "NOT_FOUND") {
      Log.shared.error("API ERROR NOT FOUND", error)
      return {
        ok: false,
        error: "NOT_FOUND",
        errorCode: 404,
        description: "Method not found",
      }
    } else if (error instanceof InlineError) {
      Log.shared.error("API ERROR", error)
      return {
        ok: false,
        error: error.type,
        errorCode: error.code,
        description: error.description,
      }
    } else if (code === "VALIDATION") {
      Log.shared.error("VALIDATION ERROR", error)
      return {
        ok: false,
        error: "INVALID_ARGS",
        errorCode: 400,
        description: "Validation error",
      }
    } else {
      Log.shared.error(`Top level error ${code} in ${path}`, error)
      return {
        ok: false,
        error: "SERVER_ERROR",
        errorCode: 500,
        description: "Server error",
      }
    }
  })

export type HandlerContext = {
  currentUserId: number
  currentSessionId: number
  ip: string | undefined
}

export type UnauthenticatedHandlerContext = {
  ip: string | undefined
}

export const makeApiRoute = <Path extends string, ISchema extends TObject, OSchema extends TSchema>(
  path: Path,
  inputType: ISchema | TUndefined,
  outputType: OSchema,
  method: (input: any, context: HandlerContext) => Promise<Static<OSchema>>,
) => {
  const response = TMakeApiResponse(outputType)
  const getRoute = new Elysia({ tags: ["GET"] }).use(authenticateGet).get(
    `/:token?${path}`,
    async ({ query: input, store, server, request }) => {
      const measure = measureTime("GET " + path)
      measure.start()
      const ip =
        request.headers.get("x-forwarded-for") ??
        request.headers.get("cf-connecting-ip") ??
        request.headers.get("x-real-ip") ??
        server?.requestIP(request)?.address
      const context = { currentUserId: store.currentUserId, currentSessionId: store.currentSessionId, ip }

      let result = await method(input, context)
      measure.end()
      return { ok: true, result } as any
    },
    {
      query: inputType,
      response: response,
    },
  )

  const postRoute = new Elysia({ tags: ["POST"] }).use(authenticate).post(
    path,
    async ({ body: input, store, server, request }) => {
      const measure = measureTime("POST " + path)
      measure.start()
      const ip =
        request.headers.get("x-forwarded-for") ??
        request.headers.get("cf-connecting-ip") ??
        request.headers.get("x-real-ip") ??
        server?.requestIP(request)?.address
      const context = {
        currentUserId: store.currentUserId,
        currentSessionId: store.currentSessionId,
        ip,
      }
      let result = await method(input, context)
      measure.end()
      return { ok: true, result } as any
    },
    {
      body: inputType,
      response: response,
    },
  )

  return new Elysia().use(getRoute).use(postRoute)
}

export const makeUploadApiRoute = <Path extends string, ISchema extends TObject, OSchema extends TSchema>(
  path: Path,
  inputType: ISchema | TUndefined,
  outputType: OSchema,
  method: (input: any, context: HandlerContext) => Promise<Static<OSchema>>,
) => {
  const response = TMakeApiResponse(outputType)

  const postRoute = new Elysia({ tags: ["POST"] }).use(authenticate).post(
    path,
    async ({ body: input, store, server, request }) => {
      const measure = measureTime("POST " + path)
      measure.start()
      const ip =
        request.headers.get("x-forwarded-for") ??
        request.headers.get("cf-connecting-ip") ??
        request.headers.get("x-real-ip") ??
        server?.requestIP(request)?.address
      const context = {
        currentUserId: store.currentUserId,
        currentSessionId: store.currentSessionId,
        ip,
      }
      let result = await method(input, context)
      measure.end()
      return { ok: true, result } as any
    },
    {
      body: inputType,
      type: "multipart",
      response: response,
    },
  )

  return new Elysia().use(postRoute)
}

export const makeUnauthApiRoute = <Path extends string, ISchema extends TObject, OSchema extends TSchema>(
  path: Path,
  inputType: ISchema,
  outputType: OSchema,
  method: (input: any, context: UnauthenticatedHandlerContext) => Promise<Static<OSchema>>,
) => {
  const response = TMakeApiResponse(outputType)
  const getRoute = new Elysia({ tags: ["GET"] }).get(
    `${path}`,
    async ({ query: input, server, request }) => {
      const measure = measureTime("POST " + path)
      measure.start()
      const ip =
        request.headers.get("x-forwarded-for") ??
        request.headers.get("cf-connecting-ip") ??
        request.headers.get("x-real-ip") ??
        server?.requestIP(request)?.address
      const context = { ip }
      let result = await method(input, context)
      measure.end()
      return { ok: true, result } as any
    },
    {
      query: inputType,
      response: response,
    },
  )

  const postRoute = new Elysia({ tags: ["POST"] }).post(
    path,
    async ({ body: input, server, request }) => {
      const measure = measureTime("POST " + path)
      measure.start()
      const ip =
        request.headers.get("x-forwarded-for") ??
        request.headers.get("cf-connecting-ip") ??
        request.headers.get("x-real-ip") ??
        server?.requestIP(request)?.address
      const context = { ip }
      let result = await method(input, context)
      measure.end()
      return { ok: true, result } as any
    },
    {
      body: inputType,
      response: response,
    },
  )

  return new Elysia().use(getRoute).use(postRoute)
}

export const TApiInputPeer = {
  peerId: TOptional(TPeerInfo),
  peerUserId: TOptional(TInputId),
  peerThreadId: TOptional(TInputId),
} as const

export function peerFromInput(input: {
  peerId?: TPeerInfo | undefined | null
  peerUserId?: number | string | undefined | null
  peerThreadId?: number | string | undefined | null
}): TPeerInfo {
  if (input.peerUserId) {
    return { userId: normalizeId(input.peerUserId) }
  } else if (input.peerThreadId) {
    return { threadId: normalizeId(input.peerThreadId) }
  } else if (input.peerId) {
    return input.peerId
  } else {
    throw new InlineError(ApiError.PEER_INVALID)
  }
}

export function reversePeerId(peerId: TPeerInfo, context: HandlerContext): TPeerInfo {
  if ("userId" in peerId) {
    return { userId: context.currentUserId }
  } else if ("threadId" in peerId) {
    return { threadId: peerId.threadId }
  } else {
    throw new InlineError(ApiError.PEER_INVALID)
  }
}
