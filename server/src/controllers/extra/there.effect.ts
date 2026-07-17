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
} from "effect/unstable/httpapi"
import {
  AuxiliaryInternalServerError,
  AuxiliaryRequestParsingFailure,
  LegacyBadRequest,
  LegacyValidationError,
  decodeLegacyJsonBody,
} from "../auxiliaryValidation.effect"

export const ThereSignup = Schema.Struct({
  email: Schema.String,
  name: Schema.optionalKey(Schema.String),
  timeZone: Schema.optionalKey(Schema.String),
}).annotate({
  identifier: "ThereSignup",
})

export type ThereSignup = typeof ThereSignup.Type

export const ThereSignupSuccess = Schema.Struct({
  ok: Schema.Literal(true),
}).annotate({
  identifier: "ThereSignupSuccess",
})

export const ThereEndpoints = {
  signup: HttpApiEndpoint.post(
    "thereSignup",
    "/api/there/signup",
    {
      payload: ThereSignup,
      success: ThereSignupSuccess,
      error: [
        LegacyBadRequest,
        LegacyValidationError,
        AuxiliaryInternalServerError,
      ],
    },
  ),
} as const

export class ThereOperationFailure extends Data.TaggedError(
  "ThereOperationFailure",
)<{
  readonly cause: unknown
}> {}

export interface ThereOperationsShape {
  readonly signup: (
    input: ThereSignup,
  ) => Effect.Effect<void, ThereOperationFailure>
}

export class ThereOperations extends Context.Service<
  ThereOperations,
  ThereOperationsShape
>()("@inline/server/auxiliary/ThereOperations") {}

export const makeThereOperations = (
  insert: (input: ThereSignup) => Promise<unknown>,
): ThereOperationsShape => ({
  signup: (input) =>
    Effect.tryPromise({
      try: () => insert(input),
      catch: (cause) =>
        new ThereOperationFailure({ cause }),
    }).pipe(Effect.asVoid),
})

const signupFields = [
  { name: "email", required: true },
  { name: "name", required: false },
  { name: "timeZone", required: false },
] as const

export const executeThereSignup = (
  request: HttpServerRequest.HttpServerRequest,
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
      ThereSignup,
      signupFields,
    )
    const operations = yield* ThereOperations
    yield* operations.signup(input)

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
