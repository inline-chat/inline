import { t } from "elysia"
export {
  encodeBotEntities,
  parseBotEntities,
  type BotUserJson,
} from "./entityCodec"

const TInt64 = t.Union([t.Number(), t.String()])
const TBotMessageEntityType = t.Union([
  t.Literal("mention"),
  t.Literal("url"),
  t.Literal("text_link"),
  t.Literal("email"),
  t.Literal("bold"),
  t.Literal("italic"),
  t.Literal("username_mention"),
  t.Literal("code"),
  t.Literal("pre"),
  t.Literal("phone_number"),
  t.Literal("thread"),
  t.Literal("thread_title"),
  t.Literal("bot_command"),
])

export const TBotMessageEntityInput = t.Object({
  // TODO(effect-cutover): remove legacy enum numbers and normalized names after
  // confirming no production Bot client use for 30 days. New thread-link
  // entities stay canonical.
  // Canonical output is lowercase.
  type: TBotMessageEntityType,
  offset: TInt64,
  length: TInt64,

  // TYPE_MENTION
  user_id: t.Optional(TInt64),

  // TYPE_TEXT_URL
  url: t.Optional(t.String()),

  // TYPE_PRE
  language: t.Optional(t.String()),

  // TYPE_THREAD
  chat_id: t.Optional(TInt64),

  // TYPE_THREAD_TITLE
  space_id: t.Optional(TInt64),
  title: t.Optional(t.String()),

})

export const TBotMessageEntitiesInput = t.Array(TBotMessageEntityInput)

export const TBotUserInline = t.Object({
  id: t.Number(),
  is_bot: t.Boolean(),
  username: t.Optional(t.String()),
  first_name: t.Optional(t.String()),
  last_name: t.Optional(t.String()),
})

export const TBotMessageEntityOutput = t.Object({
  type: t.String(), // lowercase
  offset: t.Number(),
  length: t.Number(),
  user: t.Optional(TBotUserInline), // mention only
  url: t.Optional(t.String()), // text_link only
  language: t.Optional(t.String()), // pre only
  chat_id: t.Optional(t.Number()), // thread only
  space_id: t.Optional(t.Number()), // thread_title only
  title: t.Optional(t.String()), // thread_title only
})

export const TBotMessageEntitiesOutput = t.Array(TBotMessageEntityOutput)
