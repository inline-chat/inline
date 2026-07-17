import type {
  BotApiEnvelope as NeutralBotApiEnvelope,
  BotApiError as NeutralBotApiError,
  BotApiSuccess as NeutralBotApiSuccess,
  BotUser as NeutralBotUser,
  GetMeResult as NeutralGetMeResult,
} from "@inline-chat/bot-api-types"
import { Schema } from "effect"
import { WirePositiveInteger } from "./scalars"

/**
 * Canonical Bot API user wire shape.
 *
 * It intentionally remains structurally compatible with the Effect-free public
 * `@inline-chat/bot-api-types` package. Runtime checks are stricter than its
 * TypeScript `number` fields so invalid JSON numbers cannot enter the server.
 */
export const BotUser = Schema.Struct({
  id: WirePositiveInteger,
  is_bot: Schema.Boolean,
  username: Schema.optionalKey(Schema.String),
  first_name: Schema.optionalKey(Schema.String),
  last_name: Schema.optionalKey(Schema.String),
}).annotate({
  identifier: "BotUser",
})

export type BotUser = typeof BotUser.Type

export const BotApiError = Schema.Struct({
  ok: Schema.Literal(false),
  error: Schema.optionalKey(Schema.String),
  error_code: WirePositiveInteger,
  description: Schema.String,
}).annotate({
  identifier: "BotApiError",
})

export type BotApiError = typeof BotApiError.Type

export const botApiSuccess = <S extends Schema.Top>(result: S) =>
  Schema.Struct({
    ok: Schema.Literal(true),
    result,
  })

export const botApiEnvelope = <S extends Schema.Top>(result: S) =>
  Schema.Union([botApiSuccess(result), BotApiError])

export const BotGetMeResult = Schema.Struct({
  user: BotUser,
}).annotate({
  identifier: "BotGetMeResult",
})

export type BotGetMeResult = typeof BotGetMeResult.Type

export const BotGetMeSuccess = botApiSuccess(BotGetMeResult).annotate({
  identifier: "BotGetMeSuccess",
})

export const BotGetMeEnvelope = botApiEnvelope(BotGetMeResult).annotate({
  identifier: "BotGetMeEnvelope",
})

// Compile-time guardrails: the server schemas may validate more at runtime but
// must retain the public package's neutral wire structure in both directions.
type Assert<T extends true> = T
type Extends<Left, Right> = [Left] extends [Right] ? true : false

type _BotUserExtendsPublicType = Assert<Extends<BotUser, NeutralBotUser>>
type _PublicTypeExtendsBotUser = Assert<Extends<NeutralBotUser, BotUser>>
type _BotErrorExtendsPublicType = Assert<Extends<BotApiError, NeutralBotApiError>>
type _PublicTypeExtendsBotError = Assert<Extends<NeutralBotApiError, BotApiError>>
type _BotGetMeExtendsPublicType = Assert<Extends<BotGetMeResult, NeutralGetMeResult>>
type _PublicTypeExtendsBotGetMe = Assert<Extends<NeutralGetMeResult, BotGetMeResult>>
type _BotSuccessMatchesPublicType = Assert<
  Extends<typeof BotGetMeSuccess.Type, NeutralBotApiSuccess<NeutralGetMeResult>>
>
type _BotEnvelopeMatchesPublicType = Assert<
  Extends<typeof BotGetMeEnvelope.Type, NeutralBotApiEnvelope<NeutralGetMeResult>>
>
