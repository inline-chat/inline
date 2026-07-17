import {
  Context,
  Data,
  Effect,
  ErrorReporter,
  Layer,
  Schema,
} from "effect"

export const DEFAULT_HTTP_RATE_LIMIT_MAX = 180
export const DEFAULT_HTTP_RATE_LIMIT_WINDOW_MILLIS = 60_000
export const DEFAULT_HTTP_RATE_LIMIT_CAPACITY = 5_000

const FLOOD_DESCRIPTION =
  "Too many requests. Please wait a bit before retrying."

export const HttpRateLimitErrorBody = Schema.Struct({
  ok: Schema.Literal(false),
  error: Schema.Literal("FLOOD"),
  errorCode: Schema.Literal(420),
  description: Schema.Literal(FLOOD_DESCRIPTION),
})

export type HttpRateLimitErrorBody = typeof HttpRateLimitErrorBody.Type

export const httpRateLimitErrorBody: HttpRateLimitErrorBody =
  HttpRateLimitErrorBody.make({
    ok: false,
    error: "FLOOD",
    errorCode: 420,
    description: FLOOD_DESCRIPTION,
  })

export interface HttpRateLimitPermit {
  readonly limit: number
  readonly remaining: number
  readonly resetSeconds: number
}

export class HttpRateLimitExceeded extends Data.TaggedError(
  "HttpRateLimitExceeded",
)<HttpRateLimitPermit> {
  override readonly [ErrorReporter.ignore] = true
}

export interface HttpRateLimiterShape {
  readonly consume: (
    key: string,
  ) => Effect.Effect<HttpRateLimitPermit, HttpRateLimitExceeded>
  readonly refund: (key: string) => Effect.Effect<void>
}

export class HttpRateLimiter extends Context.Service<
  HttpRateLimiter,
  HttpRateLimiterShape
>()("@inline/server/core/http/HttpRateLimiter") {}

interface RateLimitEntry {
  readonly count: number
  readonly resetAtMillis: number
}

export interface HttpRateLimiterOptions {
  readonly capacity?: number | undefined
  readonly max?: number | undefined
  readonly nowMillis?: (() => number) | undefined
  readonly windowMillis?: number | undefined
}

const positiveInteger = (
  value: number | undefined,
  fallback: number,
): number =>
  value !== undefined && Number.isFinite(value) && value > 0
    ? Math.floor(value)
    : fallback

export const parseHttpRateLimitMax = (
  input: string | undefined,
): number => {
  if (input === undefined || input.trim() === "") {
    return DEFAULT_HTTP_RATE_LIMIT_MAX
  }

  const parsed = Number(input)
  if (
    !Number.isFinite(parsed) ||
    parsed < 1 ||
    parsed > 10_000
  ) {
    return DEFAULT_HTTP_RATE_LIMIT_MAX
  }

  return Math.trunc(parsed)
}

const makeLimiter = ({
  capacity: capacityInput,
  max: maxInput,
  nowMillis = Date.now,
  windowMillis: windowMillisInput,
}: HttpRateLimiterOptions): {
  readonly clear: () => void
  readonly service: HttpRateLimiterShape
} => {
  const capacity = positiveInteger(
    capacityInput,
    DEFAULT_HTTP_RATE_LIMIT_CAPACITY,
  )
  const max = positiveInteger(maxInput, DEFAULT_HTTP_RATE_LIMIT_MAX)
  const windowMillis = positiveInteger(
    windowMillisInput,
    DEFAULT_HTTP_RATE_LIMIT_WINDOW_MILLIS,
  )
  const entries = new Map<string, RateLimitEntry>()

  const evictOldest = (): void => {
    if (entries.size < capacity) {
      return
    }

    const oldestKey = entries.keys().next().value
    if (typeof oldestKey === "string") {
      entries.delete(oldestKey)
    }
  }

  const consume = (
    key: string,
  ): Effect.Effect<HttpRateLimitPermit, HttpRateLimitExceeded> =>
    Effect.suspend(() => {
      const now = nowMillis()
      const current = entries.get(key)
      const entry =
        current === undefined || current.resetAtMillis <= now
          ? {
              count: 1,
              resetAtMillis: now + windowMillis,
            }
          : {
              count: current.count + 1,
              resetAtMillis: current.resetAtMillis,
            }

      if (current === undefined) {
        evictOldest()
      } else {
        entries.delete(key)
      }
      entries.set(key, entry)

      const permit: HttpRateLimitPermit = {
        limit: max,
        remaining: Math.max(max - entry.count, 0),
        resetSeconds: Math.max(
          0,
          Math.ceil((entry.resetAtMillis - now) / 1_000),
        ),
      }

      return entry.count > max
        ? Effect.fail(new HttpRateLimitExceeded(permit))
        : Effect.succeed(permit)
    })

  const refund = (key: string): Effect.Effect<void> =>
    Effect.sync(() => {
      const current = entries.get(key)
      if (current === undefined) {
        return
      }

      entries.delete(key)
      entries.set(key, {
        ...current,
        count: Math.max(0, current.count - 1),
      })
    })

  return {
    clear: () => {
      entries.clear()
    },
    service: {
      consume,
      refund,
    },
  }
}

/**
 * Process-scoped, fixed-window limiter matching the current 60-second global
 * policy. Its LRU storage is bounded and cleared with the application Layer.
 */
export const makeHttpRateLimiterLayer = (
  options: HttpRateLimiterOptions = {},
): Layer.Layer<HttpRateLimiter> =>
  Layer.effect(
    HttpRateLimiter,
    Effect.acquireRelease(
      Effect.sync(() => makeLimiter(options)),
      (limiter) =>
        Effect.sync(() => {
          limiter.clear()
        }),
    ).pipe(
      Effect.map((limiter) => limiter.service),
    ),
  )
