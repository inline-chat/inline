import { Data, Effect, Layer } from "effect"
import { HttpRouter, HttpServerRequest, HttpServerResponse } from "effect/unstable/http"
import { RpcError, RpcError_Code } from "@inline-chat/protocol/core"
import { HTTP_RPC_CONTENT_TYPE, HTTP_RPC_PATH, handleHttpRpcRequest } from "../../realtime/httpRpc"
import { HttpRequestContext } from "./requestContext"
import { webResponseToHttpServerResponse } from "./webResponse"

class HttpRpcTransportError extends Data.TaggedError("HttpRpcTransportError") {}

const internalErrorBody = RpcError.toBinary({
  reqMsgId: 0n,
  errorCode: RpcError_Code.INTERNAL_ERROR,
  message: "Internal server error",
  code: 500,
  retryAfterSeconds: 0,
})

const rpcRequest = Effect.gen(function* () {
  const request = yield* HttpServerRequest.HttpServerRequest
  const context = yield* HttpRequestContext
  const webRequest = yield* HttpServerRequest.toWeb(request).pipe(
    Effect.mapError(() => new HttpRpcTransportError()),
  )
  const response = yield* Effect.tryPromise({
    try: () => handleHttpRpcRequest(webRequest, { clientIp: context.clientIp }),
    catch: () => new HttpRpcTransportError(),
  })
  return webResponseToHttpServerResponse(response)
}).pipe(
  Effect.catchTag("HttpRpcTransportError", () =>
    Effect.succeed(
      HttpServerResponse.uint8Array(internalErrorBody, {
        status: 500,
        contentType: HTTP_RPC_CONTENT_TYPE,
        headers: { "cache-control": "no-store" },
      }),
    ),
  ),
)

/** Stateless protobuf RPC for request/response callers; see `realtime/httpRpc`. */
export const HttpRpcRoutesLive = Layer.effectDiscard(
  HttpRouter.HttpRouter.use((router) => router.add("POST", HTTP_RPC_PATH, rpcRequest)),
)
