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
      success: HealthHttpResponseSchema,
      error: DegradedHealthHttpResponse,
    },
  ),
  healthz: HttpApiEndpoint.get(
    "auxiliaryHealthz",
    "/healthz",
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
}

export class HealthOperations extends Context.Service<
  HealthOperations,
  HealthOperationsShape
>()("@inline/server/auxiliary/HealthOperations") {}

export const makeHealthOperations = (
  check: () => Promise<HealthHttpResponse>,
): HealthOperationsShape => ({
  check: Effect.tryPromise({
    try: check,
    catch: (cause) =>
      new HealthOperationFailure({ cause }),
  }),
})

export const executeHealth = HealthOperations.use(
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
