import {
  Context,
  Data,
  Effect,
  Schema,
} from "effect"
import {
  HttpServerResponse,
} from "effect/unstable/http"
import {
  HttpApiEndpoint,
  HttpApiSchema,
} from "effect/unstable/httpapi"
import {
  UnixSeconds,
  WireNonNegativeInteger,
} from "../core/schema/scalars"
import type {
  HealthHttpResponse,
  LivenessHttpResponse,
} from "./healthCheck"

const DatabaseHealth = Schema.Struct({
  ok: Schema.Boolean,
  latencyMs: WireNonNegativeInteger,
  error: Schema.optionalKey(
    Schema.Literal("database_unavailable"),
  ),
}).annotate({
  identifier: "AuxiliaryDatabaseHealth",
})

const LifecycleHealth = Schema.Struct({
  ok: Schema.Boolean,
  error: Schema.optionalKey(
    Schema.Literal("shutting_down"),
  ),
  signal: Schema.optionalKey(
    Schema.Literals([
      "manual",
      "timeout",
      "error",
      "SIGINT",
      "SIGTERM",
    ]),
  ),
}).annotate({
  identifier: "AuxiliaryLifecycleHealth",
})

export const HealthHttpResponseSchema = Schema.Struct({
  ok: Schema.Boolean,
  status: Schema.Literals(["ok", "degraded"]),
  timestamp: UnixSeconds,
  draining: Schema.Boolean,
  checks: Schema.Struct({
    database: DatabaseHealth,
    lifecycle: LifecycleHealth,
  }),
}).annotate({
  identifier: "AuxiliaryHealthResponse",
})

export const LivenessHttpResponseSchema = Schema.Struct({
  ok: Schema.Boolean,
  status: Schema.Literals(["ok", "degraded"]),
  timestamp: UnixSeconds,
  draining: Schema.Boolean,
  checks: Schema.Struct({
    lifecycle: LifecycleHealth,
  }),
}).annotate({
  identifier: "AuxiliaryLivenessResponse",
})

const DegradedLivenessHttpResponse =
  LivenessHttpResponseSchema.pipe(
    HttpApiSchema.status(503),
  ).annotate({
    identifier: "AuxiliaryDegradedLivenessResponse",
  })

const DegradedHealthHttpResponse =
  HealthHttpResponseSchema.pipe(
    HttpApiSchema.status(503),
  ).annotate({
    identifier: "AuxiliaryDegradedHealthResponse",
  })

export const HealthEndpoints = {
  health: HttpApiEndpoint.get(
    "auxiliaryHealth",
    "/health",
    {
      success: LivenessHttpResponseSchema,
      error: DegradedLivenessHttpResponse,
    },
  ),
  healthz: HttpApiEndpoint.get(
    "auxiliaryHealthz",
    "/healthz",
    {
      success: LivenessHttpResponseSchema,
      error: DegradedLivenessHttpResponse,
    },
  ),
  livez: HttpApiEndpoint.get(
    "auxiliaryLivez",
    "/livez",
    {
      success: LivenessHttpResponseSchema,
      error: DegradedLivenessHttpResponse,
    },
  ),
  readyz: HttpApiEndpoint.get(
    "auxiliaryReadyz",
    "/readyz",
    {
      success: HealthHttpResponseSchema,
      error: DegradedHealthHttpResponse,
    },
  ),
} as const

export class HealthOperationFailure extends Data.TaggedError(
  "HealthOperationFailure",
)<{
  readonly cause: unknown
}> {}

export interface HealthOperationsShape {
  readonly check: Effect.Effect<
    HealthHttpResponse,
    HealthOperationFailure
  >
  readonly live: Effect.Effect<
    LivenessHttpResponse,
    HealthOperationFailure
  >
}

export class HealthOperations extends Context.Service<
  HealthOperations,
  HealthOperationsShape
>()("@inline/server/auxiliary/HealthOperations") {}

export const makeHealthOperations = (
  check: () => Promise<HealthHttpResponse>,
  live: () => Promise<LivenessHttpResponse>,
): HealthOperationsShape => ({
  check: Effect.tryPromise({
    try: check,
    catch: (cause) =>
      new HealthOperationFailure({ cause }),
  }),
  live: Effect.tryPromise({
    try: live,
    catch: (cause) =>
      new HealthOperationFailure({ cause }),
  }),
})

export const executeReadiness = HealthOperations.use(
  (operations) =>
    operations.check.pipe(
      Effect.map((result) =>
        HttpServerResponse.jsonUnsafe(
          result,
          {
            status: result.ok ? 200 : 503,
            headers: {
              "content-type":
                "application/json;charset=utf-8",
            },
          },
        ),
      ),
    ),
)

export const executeLiveness = HealthOperations.use(
  (operations) =>
    operations.live.pipe(
      Effect.map((result) =>
        HttpServerResponse.jsonUnsafe(
          result,
          {
            status: result.ok ? 200 : 503,
            headers: {
              "content-type":
                "application/json;charset=utf-8",
            },
          },
        ),
      ),
    ),
)
