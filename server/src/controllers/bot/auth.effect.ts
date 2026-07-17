import {
  Context,
  Data,
  Effect,
  ErrorReporter,
} from "effect"

export class BotAuthorizationRejected extends Data.TaggedError(
  "BotAuthorizationRejected",
)<{
  readonly error: "UNAUTHORIZED"
  readonly errorCode: 401
  readonly description: "Unauthorized"
}> {
  override readonly [ErrorReporter.ignore] = true
}

export class BotAuthorizationFailure extends Data.TaggedError(
  "BotAuthorizationFailure",
)<{
  readonly cause: unknown
}> {}

export interface BotAuthorizationShape {
  readonly requireBot: (
    userId: number,
  ) => Effect.Effect<
    void,
    BotAuthorizationRejected | BotAuthorizationFailure
  >
}

export class BotAuthorization extends Context.Service<
  BotAuthorization,
  BotAuthorizationShape
>()("@inline/server/bot/BotAuthorization") {}

export interface BotAuthorizationAdapterOptions {
  readonly isBot: (userId: number) => Promise<boolean>
}

export const makeBotAuthorization = ({
  isBot,
}: BotAuthorizationAdapterOptions): BotAuthorizationShape => ({
  requireBot: (userId) =>
    Effect.tryPromise({
      try: () => isBot(userId),
      catch: (cause) =>
        new BotAuthorizationFailure({ cause }),
    }).pipe(
      Effect.flatMap((authorized) =>
        authorized
          ? Effect.void
          : Effect.fail(
              new BotAuthorizationRejected({
                error: "UNAUTHORIZED",
                errorCode: 401,
                description: "Unauthorized",
              }),
            ),
      ),
    ),
})

export const missingBotAuthentication =
  (): BotAuthorizationRejected =>
    new BotAuthorizationRejected({
      error: "UNAUTHORIZED",
      errorCode: 401,
      description: "Unauthorized",
    })
