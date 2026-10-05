import { Data, Effect, Layer } from "effect"
import { HttpRouter, HttpServerRequest, HttpServerResponse } from "effect/unstable/http"
import { handleGridTranscriptionWorkerRequest } from "../../modules/grid/transcription/worker"
import { webResponseToHttpServerResponse } from "./webResponse"

export const gridTranscriptionWorkerPaths = ["heartbeat", "claim", "renew", "admit", "final", "stopped"].map(
  (action) => `/_internal/grid-transcription/${action}` as const,
)

class GridTranscriptionTransportError extends Data.TaggedError("GridTranscriptionTransportError") {}

const workerRequest = Effect.gen(function* () {
  const request = yield* HttpServerRequest.HttpServerRequest
  const webRequest = yield* HttpServerRequest.toWeb(request).pipe(
    Effect.mapError(() => new GridTranscriptionTransportError()),
  )
  const response = yield* Effect.tryPromise({
    try: () => handleGridTranscriptionWorkerRequest(webRequest),
    catch: () => new GridTranscriptionTransportError(),
  })
  return webResponseToHttpServerResponse(response)
}).pipe(
  Effect.catchTag("GridTranscriptionTransportError", () =>
    Effect.succeed(HttpServerResponse.jsonUnsafe({ error: "unavailable" }, { status: 503 })),
  ),
)

/** Internal worker authentication stays inside the bounded request handler. */
export const GridTranscriptionWorkerRoutesLive = Layer.effectDiscard(
  HttpRouter.HttpRouter.use((router) =>
    Effect.forEach(gridTranscriptionWorkerPaths, (path) => router.add("POST", path, workerRequest)),
  ),
)
