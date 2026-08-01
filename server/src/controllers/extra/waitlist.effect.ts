import {
  Context,
  Data,
  Effect,
  Schema,
} from "effect"
import {
  HttpServerRequest,
  HttpServerResponse,
} from "effect/unstable/http"
import {
  HttpApiEndpoint,
  HttpApiSchema,
} from "effect/unstable/httpapi"
import {
  WireNonNegativeInteger,
} from "../../core/schema/scalars"
import {
  AuxiliaryInternalServerError,
  AuxiliaryRequestParsingFailure,
  LegacyBadRequest,
  LegacyValidationError,
  decodeLegacyJsonBody,
} from "../auxiliaryValidation.effect"

export const WaitlistSubscription = Schema.Struct({
  email: Schema.String,
  name: Schema.optionalKey(Schema.String),
  userAgent: Schema.optionalKey(Schema.String),
  timeZone: Schema.optionalKey(Schema.String),
}).annotate({
  identifier: "WaitlistSubscription",
})

export type WaitlistSubscription =
  typeof WaitlistSubscription.Type

export const WaitlistSubscriptionSuccess = Schema.Struct({
  ok: Schema.Literal(true),
}).annotate({
  identifier: "WaitlistSubscriptionSuccess",
})

const WaitlistVerification = Schema.Literal(
  "todo",
).pipe(
  HttpApiSchema.asText(),
).annotate({
  identifier: "WaitlistVerification",
})

export const WaitlistEndpoints = {
  count: HttpApiEndpoint.get(
    "waitlistSubscriberCount",
    "/waitlist/super_secret_sub_count",
    {
      success: WireNonNegativeInteger,
      error: AuxiliaryInternalServerError,
    },
  ),
  subscribe: HttpApiEndpoint.post(
    "waitlistSubscribe",
    "/waitlist/subscribe",
    {
      payload: WaitlistSubscription,
      success: WaitlistSubscriptionSuccess,
      error: [
        LegacyBadRequest,
        LegacyValidationError,
        AuxiliaryInternalServerError,
      ],
    },
  ),
  verify: HttpApiEndpoint.post(
    "waitlistVerify",
    "/waitlist/verify",
    {
      success: WaitlistVerification,
    },
  ),
} as const

export type WaitlistOperation =
  | "count"
  | "subscribe"

export class WaitlistOperationFailure extends Data.TaggedError(
  "WaitlistOperationFailure",
)<{
  readonly operation: WaitlistOperation
  readonly cause: unknown
}> {}

export interface WaitlistOperationsShape {
  readonly count: Effect.Effect<
    number,
    WaitlistOperationFailure
  >
  readonly subscribe: (
    input: WaitlistSubscription,
    clientIp: string | undefined,
  ) => Effect.Effect<void, WaitlistOperationFailure>
}

export class WaitlistOperations extends Context.Service<
  WaitlistOperations,
  WaitlistOperationsShape
>()("@inline/server/auxiliary/WaitlistOperations") {}

export interface WaitlistOperationDependencies {
  readonly count: () => Promise<number>
  readonly insert: (
    input: WaitlistSubscription,
  ) => Promise<boolean>
  readonly notify: (
    input: WaitlistSubscription,
    clientIp: string | undefined,
  ) => Promise<void>
  readonly noteNotificationFailure: (
    cause: unknown,
  ) => void
}

export const makeWaitlistOperations = ({
  count,
  insert,
  notify,
  noteNotificationFailure,
}: WaitlistOperationDependencies): WaitlistOperationsShape => ({
  count: Effect.tryPromise({
    try: count,
    catch: (cause) =>
      new WaitlistOperationFailure({
        operation: "count",
        cause,
      }),
  }),
  subscribe: (input, clientIp) =>
    Effect.tryPromise({
      try: () => insert(input),
      catch: (cause) =>
        new WaitlistOperationFailure({
          operation: "subscribe",
          cause,
        }),
    }).pipe(
      Effect.flatMap((created) =>
        created
          ? Effect.tryPromise({
              try: () => notify(input, clientIp),
              catch: (cause) => cause,
            }).pipe(
              Effect.catch((cause) =>
                Effect.sync(() =>
                  noteNotificationFailure(cause),
                ),
              ),
            )
          : Effect.void,
      ),
    ),
})

const subscriptionFields = [
  { name: "email", required: true },
  { name: "name", required: false },
  { name: "userAgent", required: false },
  { name: "timeZone", required: false },
] as const

export const executeWaitlistCount =
  WaitlistOperations.use((operations) =>
    operations.count.pipe(
      Effect.map((value) =>
        HttpServerResponse.jsonUnsafe(value, {
          headers: {
            "content-type":
              "application/json;charset=utf-8",
          },
        }),
      ),
    ),
  )

export const executeWaitlistSubscribe = (
  request: HttpServerRequest.HttpServerRequest,
  clientIp: string | undefined,
) =>
  Effect.gen(function* () {
    const webRequest =
      yield* HttpServerRequest.toWeb(request).pipe(
        Effect.mapError(
          (cause) =>
            new AuxiliaryRequestParsingFailure({
              cause,
            }),
        ),
      )
    const input = yield* decodeLegacyJsonBody(
      webRequest,
      WaitlistSubscription,
      subscriptionFields,
    )
    const operations = yield* WaitlistOperations
    yield* operations.subscribe(input, clientIp)

    return HttpServerResponse.jsonUnsafe(
      { ok: true },
      {
        headers: {
          "content-type":
            "application/json;charset=utf-8",
        },
      },
    )
  })

export const executeWaitlistVerify =
  Effect.succeed(
    HttpServerResponse.raw(
      new TextEncoder().encode("todo"),
    ),
  )
