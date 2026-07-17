import {
  authenticate,
  authenticateGet,
} from "@in/server/controllers/plugins"
import { ApiError, InlineError } from "@in/server/types/errors"
import { Log } from "@in/server/utils/log"
import { recordApiError } from "@in/server/utils/metrics"
import Elysia, { type TSchema, type Static } from "elysia"
import { type TUndefined, type TObject } from "@sinclair/typebox"
import { TOptional, TPeerInfo } from "@in/server/api-types"
import { normalizeId, TInputId } from "@in/server/types/methods"
import { measureTime } from "@in/server/utils/helpers/measure"
import { getIp } from "@in/server/utils/ip"
import { handleBotError } from "@in/server/controllers/bot/error"
import { TApiEnvelope } from "@in/server/controllers/bot/helpers"
import { TMakeApiResponse } from "./apiResponse"

export { handleError } from "./apiErrorHandler"
export { TMakeApiResponse } from "./apiResponse"
export {
  makeUnauthApiRoute,
  type UnauthenticatedHandlerContext,
} from "./unauthApiRoute"

export type HandlerContext = {
  currentUserId: number
  currentSessionId: number
  ip: string | undefined
}

export const makeApiRoute = <Path extends string, ISchema extends TObject, OSchema extends TSchema>(
  path: Path,
  inputType: ISchema | TUndefined,
  outputType: OSchema,
  method: (input: any, context: HandlerContext) => Promise<Static<OSchema>>,
): any => {
  const response = TMakeApiResponse(outputType)
  const getRoute: any = new Elysia({ tags: ["GET"] })
  getRoute.use(authenticateGet).get(
    `/:token?${path}`,
    async ({ query: input, store, server, request }: any) => {
      const measure = measureTime("GET " + path)
      measure.start()
      const ip = getIp(request, server)
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

  const postRoute: any = new Elysia({ tags: ["POST"] })
  postRoute.use(authenticate).post(
    path,
    async ({ body: input, store, server, request }: any) => {
      const measure = measureTime("POST " + path)
      measure.start()
      const ip = getIp(request, server)
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

  return (new Elysia() as any).use(getRoute).use(postRoute)
}

export const makeBotApiCompatRoute = <Path extends string, ISchema extends TObject, OSchema extends TSchema>(
  path: Path,
  inputType: ISchema | TUndefined,
  outputType: OSchema,
  method: (input: any, context: HandlerContext) => Promise<Static<OSchema>>,
): any => {
  const response = TApiEnvelope(outputType)
  const botError = (error: unknown, set: { status?: number | string }) => {
    recordApiError()

    if (error instanceof InlineError) {
      set.status = error.code
      Log.shared.error("BOT API COMPAT ERROR", error)
      return {
        ok: false,
        error: error.type,
        error_code: error.code,
        description: error.description,
      }
    }

    set.status = 500
    Log.shared.error("Bot API compat top level error", error)
    return {
      ok: false,
      error: "SERVER_ERROR",
      error_code: 500,
      description: "Server error",
    }
  }

  const getRoute: any = new Elysia({ tags: ["GET"] })
  getRoute.use(authenticateGet).get(
    `/:token?${path}`,
    async ({ query: input, store, server, request, set }: any) => {
      const measure = measureTime("GET " + path)
      measure.start()
      const ip = getIp(request, server)
      const context = { currentUserId: store.currentUserId, currentSessionId: store.currentSessionId, ip }

      try {
        let result = await method(input, context)
        measure.end()
        return { ok: true, result } as any
      } catch (error) {
        measure.end()
        return botError(error, set)
      }
    },
    {
      query: inputType,
      response,
    },
  )

  const postRoute: any = new Elysia({ tags: ["POST"] })
  postRoute.use(authenticate).post(
    path,
    async ({ body: input, store, server, request, set }: any) => {
      const measure = measureTime("POST " + path)
      measure.start()
      const ip = getIp(request, server)
      const context = {
        currentUserId: store.currentUserId,
        currentSessionId: store.currentSessionId,
        ip,
      }
      try {
        let result = await method(input, context)
        measure.end()
        return { ok: true, result } as any
      } catch (error) {
        measure.end()
        return botError(error, set)
      }
    },
    {
      body: inputType,
      response,
    },
  )

  return (new Elysia() as any).use(handleBotError).use(getRoute).use(postRoute)
}

export const makeUploadApiRoute = <Path extends string, ISchema extends TObject, OSchema extends TSchema>(
  path: Path,
  inputType: ISchema | TUndefined,
  outputType: OSchema,
  method: (input: any, context: HandlerContext) => Promise<Static<OSchema>>,
): any => {
  const response = TMakeApiResponse(outputType)

  const postRoute: any = new Elysia({ tags: ["POST"] })
  postRoute.use(authenticate).post(
    path,
    async ({ body: input, store, server, request }: any) => {
      const measure = measureTime("POST " + path)
      measure.start()
      const ip = getIp(request, server)
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

  return (new Elysia() as any).use(postRoute)
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
