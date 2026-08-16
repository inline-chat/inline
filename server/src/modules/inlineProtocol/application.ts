import {
  RealtimeV3Request,
  RealtimeV3Response,
  RealtimeV3Update,
  RpcError_Code,
  type AuthBeginRequest,
  type AuthBeginResult,
  type AuthCompleteRequest,
  type AuthCompleteResult,
  type CreateHttpUploadRequest,
  type CreateHttpUploadResult,
  type FinishHttpUploadRequest,
  type FinishHttpUploadResult,
  type ServerProtocolMessage,
} from "@inline-chat/protocol/core"
import type {
  ServerApplicationAuthorization,
  ServerApplicationDispatcher,
} from "@inline-chat/protocol/server"
import { handleRpcCall } from "@in/server/realtime/handlers/_rpc"
import { toRealtimeRpcError } from "@in/server/realtime/rpcErrorBoundary"
import type { RealtimeRequestMetadata } from "@in/server/realtime/types"

export type InlineProtocolApplicationContext = {
  authorization: ServerApplicationAuthorization
  metadata?: RealtimeRequestMetadata
}

export interface InlineProtocolApplicationOperations {
  authBegin(input: AuthBeginRequest, context: InlineProtocolApplicationContext): Promise<AuthBeginResult>
  authComplete(input: AuthCompleteRequest, context: InlineProtocolApplicationContext): Promise<AuthCompleteResult>
  createHttpUpload(
    input: CreateHttpUploadRequest,
    context: InlineProtocolApplicationContext,
  ): Promise<CreateHttpUploadResult>
  finishHttpUpload(
    input: FinishHttpUploadRequest,
    context: InlineProtocolApplicationContext,
  ): Promise<FinishHttpUploadResult>
}

const unauthorizedResponse = (): Uint8Array => RealtimeV3Response.toBinary({
  body: {
    oneofKind: "rpcError",
    rpcError: {
      reqMsgId: 0n,
      errorCode: RpcError_Code.UNAUTHENTICATED,
      message: "Unauthenticated",
      code: 401,
    },
  },
})

const errorResponse = (error: unknown): Uint8Array => {
  const rpc = toRealtimeRpcError(error)
  return RealtimeV3Response.toBinary({
    body: {
      oneofKind: "rpcError",
      rpcError: {
        reqMsgId: 0n,
        errorCode: rpc.code,
        message: rpc.message,
        code: rpc.codeNumber,
      },
    },
  })
}

const sendV3Update = (
  message: ServerProtocolMessage,
  sendUpdate: (payload: Uint8Array) => void,
): void => {
  if (message.body.oneofKind !== "message") return
  sendUpdate(RealtimeV3Update.toBinary({ message: message.body.message }))
}

export const makeInlineProtocolApplicationDispatcher = (input: {
  operations: InlineProtocolApplicationOperations
  connectionId: string
  metadata?: RealtimeRequestMetadata
  onAuthorized?: (authorization: ServerApplicationAuthorization) => void
}): ServerApplicationDispatcher => ({
  dispatch: async ({ payload, authorization, sendUpdate }) => {
    let request
    try {
      request = RealtimeV3Request.fromBinary(payload)
    } catch (error) {
      return { kind: "result", payload: errorResponse(error) }
    }
    const context = { authorization, metadata: input.metadata }
    try {
      if (authorization.permanent && authorization.userId === undefined) {
        if (request.body.oneofKind === "authBegin") {
          const result = await input.operations.authBegin(request.body.authBegin, context)
          return {
            kind: "result",
            payload: RealtimeV3Response.toBinary({
              body: { oneofKind: "authBegin", authBegin: result },
            }),
          }
        }
        if (request.body.oneofKind === "authComplete") {
          const result = await input.operations.authComplete(request.body.authComplete, context)
          return {
            kind: "result",
            payload: RealtimeV3Response.toBinary({
              body: { oneofKind: "authComplete", authComplete: result },
            }),
          }
        }
        return { kind: "result", payload: unauthorizedResponse() }
      }

      if (!authorization.temporaryBound || authorization.userId === undefined ||
          authorization.accountSessionId === undefined) {
        return { kind: "result", payload: unauthorizedResponse() }
      }
      input.onAuthorized?.(authorization)

      if (request.body.oneofKind === "rpc") {
        const result = await handleRpcCall(request.body.rpc, {
          userId: authorization.userId,
          sessionId: authorization.accountSessionId,
          connectionId: input.connectionId,
          sendRaw: (message) => sendV3Update(message, sendUpdate),
          sendRpcReply: () => {},
        })
        return {
          kind: "result",
          payload: RealtimeV3Response.toBinary({
            body: {
              oneofKind: "rpcResult",
              rpcResult: { reqMsgId: 0n, result },
            },
          }),
        }
      }
      if (request.body.oneofKind === "createHttpUpload") {
        const result = await input.operations.createHttpUpload(request.body.createHttpUpload, context)
        return {
          kind: "result",
          payload: RealtimeV3Response.toBinary({
            body: { oneofKind: "createHttpUpload", createHttpUpload: result },
          }),
        }
      }
      if (request.body.oneofKind === "finishHttpUpload") {
        const result = await input.operations.finishHttpUpload(request.body.finishHttpUpload, context)
        return {
          kind: "result",
          payload: RealtimeV3Response.toBinary({
            body: { oneofKind: "finishHttpUpload", finishHttpUpload: result },
          }),
        }
      }
      return { kind: "result", payload: unauthorizedResponse() }
    } catch (error) {
      return { kind: "result", payload: errorResponse(error) }
    }
  },
})
