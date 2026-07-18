import type {
  BotApiEnvelope as NeutralBotApiEnvelope,
  BotApiError as NeutralBotApiError,
  BotApiSuccess as NeutralBotApiSuccess,
  BotUser as NeutralBotUser,
  GetMeResult as NeutralGetMeResult,
} from "@inline-chat/bot-api-types"
import { Schema } from "effect"
import { UserId } from "./identifiers"
import { HttpStatusCode } from "./scalars"

/**
 * Canonical Bot API user wire shape.
 *
 * Its wire shape remains compatible with the Effect-free public
 * `@inline-chat/bot-api-types` package. The server decodes the neutral numeric
 * field into a UserId so identities cannot be mixed inside Effect code.
 */
export const BotUser = Schema.Struct({
  id: UserId.annotateKey({
    description: "Unique identifier for this Inline user.",
  }),
  is_bot: Schema.Boolean.annotateKey({
    description: "True when the user represents a bot account.",
  }),
  username: Schema.optionalKey(Schema.String).annotateKey({
    description: "Public username, without the leading @.",
  }),
  first_name: Schema.optionalKey(Schema.String).annotateKey({
    description: "User's first or display name.",
  }),
  last_name: Schema.optionalKey(Schema.String).annotateKey({
    description: "User's last name, when available.",
  }),
}).annotate({
  identifier: "BotUser",
  description: "Basic information about an Inline user or bot.",
  examples: [
    {
      id: UserId.make(284_901),
      is_bot: true,
      username: "deploy_bot",
      first_name: "Deploy Bot",
    },
  ],
})

export type BotUser = typeof BotUser.Type

export const BotApiError = Schema.Struct({
  ok: Schema.Literal(false).annotateKey({
    description: "Always false for an unsuccessful request.",
  }),
  error: Schema.optionalKey(Schema.String).annotateKey({
    description: "Stable machine-readable error name.",
  }),
  error_code: HttpStatusCode.annotateKey({
    description: "HTTP status code returned for the request.",
  }),
  description: Schema.String.annotateKey({
    description: "Human-readable explanation of the error.",
  }),
}).annotate({
  identifier: "BotApiError",
  description: "Error envelope returned by the Inline Bot API.",
})

export type BotApiError = typeof BotApiError.Type

export const botApiSuccess = <S extends Schema.Top>(result: S) =>
  Schema.Struct({
    ok: Schema.Literal(true).annotateKey({
      description: "Always true for a successful request.",
    }),
    result: result.annotateKey({
      description: "Method-specific response payload.",
    }),
  })

export const botApiEnvelope = <S extends Schema.Top>(result: S) =>
  Schema.Union([botApiSuccess(result), BotApiError])

export const BotGetMeResult = Schema.Struct({
  user: BotUser.annotateKey({
    description: "The bot account authenticated by the supplied token.",
  }),
}).annotate({
  identifier: "BotGetMeResult",
  description: "Information about the authenticated bot.",
})

export type BotGetMeResult = typeof BotGetMeResult.Type

export const BotGetMeSuccess = botApiSuccess(BotGetMeResult).annotate({
  identifier: "BotGetMeSuccess",
  description: "Successful getMe response.",
  examples: [
    {
      ok: true,
      result: {
        user: {
          id: UserId.make(284_901),
          is_bot: true,
          username: "deploy_bot",
          first_name: "Deploy Bot",
        },
      },
    },
  ],
})

export const BotGetMeEnvelope = botApiEnvelope(BotGetMeResult).annotate({
  identifier: "BotGetMeEnvelope",
})

// Compile-time guardrails: branded server values must remain valid neutral
// public DTOs. The reverse direction intentionally requires schema decoding.
type Assert<T extends true> = T
type Extends<Left, Right> = [Left] extends [Right] ? true : false

type _BotUserExtendsPublicType = Assert<Extends<BotUser, NeutralBotUser>>
type _BotErrorExtendsPublicType = Assert<Extends<BotApiError, NeutralBotApiError>>
type _PublicTypeExtendsBotError = Assert<Extends<NeutralBotApiError, BotApiError>>
type _BotGetMeExtendsPublicType = Assert<Extends<BotGetMeResult, NeutralGetMeResult>>
type _BotSuccessMatchesPublicType = Assert<
  Extends<typeof BotGetMeSuccess.Type, NeutralBotApiSuccess<NeutralGetMeResult>>
>
type _BotEnvelopeMatchesPublicType = Assert<
  Extends<typeof BotGetMeEnvelope.Type, NeutralBotApiEnvelope<NeutralGetMeResult>>
>
