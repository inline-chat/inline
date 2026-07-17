import {
  Context,
  Data,
  Effect,
} from "effect"

export type OAuthHttpOperation =
  | "metadata"
  | "register"
  | "authorize"
  | "sendEmailCode"
  | "verifyEmailCode"
  | "consent"
  | "token"
  | "revoke"
  | "introspect"

export interface OAuthHttpInput {
  readonly request: Request
  readonly clientIp?: string | undefined
}

export class OAuthHttpFailure extends Data.TaggedError(
  "OAuthHttpFailure",
)<{
  readonly operation: OAuthHttpOperation
  readonly cause: unknown
  readonly publicResponse?: Response | undefined
}> {}

export interface OAuthHttpServiceShape {
  readonly execute: (
    operation: OAuthHttpOperation,
    input: OAuthHttpInput,
  ) => Effect.Effect<Response, OAuthHttpFailure>
}

export class OAuthHttpService extends Context.Service<
  OAuthHttpService,
  OAuthHttpServiceShape
>()("@inline/server/oauth/OAuthHttpService") {}
