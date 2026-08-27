import { createHash } from "node:crypto"
import { Context, Data, Effect, Option, Schema } from "effect"
import { HttpServerRequest, HttpServerResponse } from "effect/unstable/http"
import { HttpApiEndpoint, HttpApiSchema } from "effect/unstable/httpapi"
import { InMemoryRateLimiter } from "@in/server/modules/oauth/rateLimiter"
import {
  AuxiliaryInternalServerError,
  AuxiliaryRequestRejected,
} from "../auxiliaryValidation.effect"

export const SpaceJoinResolveInput = Schema.Union([
  Schema.Struct({
    kind: Schema.Literal("public_handle"),
    value: Schema.String,
  }),
  Schema.Struct({
    kind: Schema.Literal("invite_token"),
    value: Schema.String,
  }),
]).annotate({ identifier: "SpaceJoinResolveInput" })

export type SpaceJoinResolveInput = typeof SpaceJoinResolveInput.Type

export const SpaceJoinResolveSuccess = Schema.Struct({
  name: Schema.String,
}).annotate({ identifier: "SpaceJoinResolveSuccess" })

const SpaceJoinResolveUnavailable = Schema.Void.pipe(
  HttpApiSchema.status(404),
).annotate({ identifier: "SpaceJoinResolveUnavailable" })

const SpaceJoinResolveRateLimited = Schema.Struct({
  error: Schema.Literal("rate_limited"),
}).pipe(HttpApiSchema.status(429)).annotate({
  identifier: "SpaceJoinResolveRateLimited",
})

export const SpaceJoinEndpoints = {
  resolve: HttpApiEndpoint.post(
    "spaceJoinResolve",
    "/v1/space-join/resolve",
    {
      payload: SpaceJoinResolveInput,
      success: SpaceJoinResolveSuccess,
      error: [
        SpaceJoinResolveUnavailable,
        SpaceJoinResolveRateLimited,
        AuxiliaryInternalServerError,
      ],
    },
  ),
} as const

export class SpaceJoinOperationFailure extends Data.TaggedError(
  "SpaceJoinOperationFailure",
)<{ readonly cause: unknown }> {}

export class SpaceJoinRateLimitExceeded extends Data.TaggedError(
  "SpaceJoinRateLimitExceeded",
)<{ readonly retryAfterSeconds: number }> {}

export class SpaceJoinRequestFailure extends Data.TaggedError(
  "SpaceJoinRequestFailure",
)<{ readonly cause: unknown }> {}

export interface SpaceJoinResolution {
  readonly name: string
}

export interface SpaceJoinOperationsShape {
  readonly consumeRequest: (
    clientIp: string,
  ) => Effect.Effect<void, SpaceJoinRateLimitExceeded>
  readonly resolve: (
    input: SpaceJoinResolveInput,
    clientIp: string,
  ) => Effect.Effect<
    SpaceJoinResolution | null,
    SpaceJoinOperationFailure | SpaceJoinRateLimitExceeded
  >
}

export class SpaceJoinOperations extends Context.Service<
  SpaceJoinOperations,
  SpaceJoinOperationsShape
>()("@inline/server/auxiliary/SpaceJoinOperations") {}

export interface SpaceJoinOperationDependencies {
  readonly limiter: InMemoryRateLimiter
  readonly nowMs?: () => number
  readonly resolve: (
    input: SpaceJoinResolveInput,
  ) => Promise<SpaceJoinResolution | null>
}

const allResolveRule = { max: 60, windowMs: 60_000 }
const privateResolveRule = { max: 20, windowMs: 60_000 }
const referenceResolveRule = { max: 120, windowMs: 10 * 60_000 }

const referenceKey = (input: SpaceJoinResolveInput): string => {
  const value = input.kind === "public_handle"
    ? input.value.trim().replace(/^@/, "").toLowerCase()
    : input.value
  return createHash("sha256")
    .update(input.kind)
    .update("\0")
    .update(value)
    .digest("base64url")
}

export const makeSpaceJoinOperations = ({
  limiter,
  nowMs = Date.now,
  resolve,
}: SpaceJoinOperationDependencies): SpaceJoinOperationsShape => ({
  consumeRequest: (clientIp) =>
    Effect.gen(function* () {
      const result = limiter.consume({
        key: `space-join:ip:${clientIp}`,
        nowMs: nowMs(),
        rule: allResolveRule,
      })
      if (!result.allowed) {
        return yield* new SpaceJoinRateLimitExceeded({
          retryAfterSeconds: result.retryAfterSeconds,
        })
      }
    }),
  resolve: (input, clientIp) =>
    Effect.gen(function* () {
      const now = nowMs()
      const checks = [
        ...(input.kind === "invite_token"
          ? [limiter.consume({
              key: `space-join:private-ip:${clientIp}`,
              nowMs: now,
              rule: privateResolveRule,
            })]
          : []),
        limiter.consume({
          key: `space-join:reference:${referenceKey(input)}`,
          nowMs: now,
          rule: referenceResolveRule,
        }),
      ]
      const denied = checks.find((result) => !result.allowed)
      if (denied) {
        return yield* new SpaceJoinRateLimitExceeded({
          retryAfterSeconds: denied.retryAfterSeconds,
        })
      }

      return yield* Effect.tryPromise({
        try: () => resolve(input),
        catch: (cause) => new SpaceJoinOperationFailure({ cause }),
      })
    }),
})

const privateHeaders = {
  "cache-control": "private, no-store",
  "referrer-policy": "no-referrer",
  "x-robots-tag": "noindex, nofollow, noarchive, nosnippet",
} as const

const unavailable = (): HttpServerResponse.HttpServerResponse =>
  HttpServerResponse.empty({ status: 404, headers: privateHeaders })

export const spaceJoinInternalServerError = (): HttpServerResponse.HttpServerResponse =>
  HttpServerResponse.text("Internal Server Error", {
    status: 500,
    headers: privateHeaders,
  })

const rateLimited = (retryAfterSeconds: number): HttpServerResponse.HttpServerResponse =>
  HttpServerResponse.jsonUnsafe(
    { error: "rate_limited" },
    {
      status: 429,
      headers: {
        ...privateHeaders,
        "retry-after": String(retryAfterSeconds),
      },
    },
  )

export const MAX_SPACE_JOIN_RESOLVE_BODY_BYTES = 1_024

const decodeSpaceJoinResolveBody = (
  request: Request,
): Effect.Effect<SpaceJoinResolveInput | null> =>
  Effect.promise(async () => {
    const contentType = request.headers.get("content-type")
      ?.split(";", 1)[0]
      ?.trim()
      .toLowerCase()
    if (contentType !== "application/json") return null

    const declaredLength = Number(request.headers.get("content-length"))
    if (Number.isFinite(declaredLength) && declaredLength > MAX_SPACE_JOIN_RESOLVE_BODY_BYTES) {
      return null
    }

    const reader = request.body?.getReader()
    if (!reader) return null

    const chunks: Uint8Array[] = []
    let totalBytes = 0
    try {
      while (true) {
        const result = await reader.read()
        if (result.done) break
        totalBytes += result.value.byteLength
        if (totalBytes > MAX_SPACE_JOIN_RESOLVE_BODY_BYTES) {
          await reader.cancel()
          return null
        }
        chunks.push(result.value)
      }
    } catch {
      return null
    } finally {
      reader.releaseLock()
    }

    const body = new Uint8Array(totalBytes)
    let offset = 0
    for (const chunk of chunks) {
      body.set(chunk, offset)
      offset += chunk.byteLength
    }

    try {
      const decoded = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(body))
      return Option.getOrNull(
        Schema.decodeUnknownOption(SpaceJoinResolveInput)(decoded),
      )
    } catch {
      return null
    }
  })

const rejectRateLimit = (
  effect: Effect.Effect<void, SpaceJoinRateLimitExceeded>,
): Effect.Effect<void, AuxiliaryRequestRejected> =>
  effect.pipe(
    Effect.mapError((failure) =>
      new AuxiliaryRequestRejected({
        response: rateLimited(failure.retryAfterSeconds),
      })),
  )

export const executeSpaceJoinResolve = (
  request: HttpServerRequest.HttpServerRequest,
  clientIp: string,
) => Effect.gen(function* () {
  const operations = yield* SpaceJoinOperations
  yield* rejectRateLimit(operations.consumeRequest(clientIp))

  const webRequest = yield* HttpServerRequest.toWeb(request).pipe(
    Effect.mapError((cause) => new SpaceJoinRequestFailure({ cause })),
  )
  const input = yield* decodeSpaceJoinResolveBody(webRequest)
  if (!input) return unavailable()

  const resolution = yield* operations.resolve(input, clientIp).pipe(
    Effect.catchTag("SpaceJoinRateLimitExceeded", (failure) =>
      Effect.fail(new AuxiliaryRequestRejected({
        response: rateLimited(failure.retryAfterSeconds),
      }))),
  )
  if (!resolution) return unavailable()

  return HttpServerResponse.jsonUnsafe(resolution, {
    headers: privateHeaders,
  })
})
