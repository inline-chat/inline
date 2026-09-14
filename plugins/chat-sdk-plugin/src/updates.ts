import type { BotUpdate } from "@inline-chat/bot-api-types"

const record = (value: unknown): value is Record<string, unknown> =>
  typeof value === "object" && value !== null && !Array.isArray(value)
const integer = (value: unknown): value is number =>
  Number.isSafeInteger(value) && (value as number) > 0 && (value as number) <= 4_503_599_627_370_495
const optionalString = (value: unknown) => value === undefined || typeof value === "string"
function user(value: unknown): boolean {
  return (
    record(value) &&
    integer(value.id) &&
    typeof value.is_bot === "boolean" &&
    [value.first_name, value.last_name, value.username].every(optionalString)
  )
}
function chat(value: unknown): boolean {
  return record(value) && integer(value.chat_id) && (value.type === "user" || value.type === "thread")
}
function message(value: unknown): boolean {
  if (
    !record(value) ||
    !integer(value.message_id) ||
    !user(value.from) ||
    !integer(value.date) ||
    !record(value.peer_id) ||
    !optionalString(value.text) ||
    (value.edit_date !== undefined && !integer(value.edit_date))
  )
    return false
  const peer = value.peer_id
  if (!(integer(peer.user_id) && peer.chat_id === undefined) && !(integer(peer.chat_id) && peer.user_id === undefined))
    return false
  if (
    value.entities !== undefined &&
    (!Array.isArray(value.entities) ||
      !value.entities.every(
        (entity) =>
          record(entity) && typeof entity.type === "string" && (entity.user === undefined || user(entity.user)),
      ))
  )
    return false
  if (
    value.media !== undefined &&
    (!record(value.media) ||
      (value.media.type !== "nudge" && (!record(value.media.file) || typeof value.media.file.file_id !== "string")))
  )
    return false
  return true
}

/** Validate fields consumed by dispatch; retain unknown additive API fields in raw payloads. */
export function isInlineUpdate(value: unknown): value is BotUpdate {
  if (!record(value) || !integer(value.update_id)) return false
  const keys = ["message", "edited_message", "message_action", "message_reaction", "bot_participation"].filter(
    (key) => key in value,
  )
  if (keys.length !== 1) return false
  if ("message" in value) return message(value.message)
  if ("edited_message" in value) return message(value.edited_message)
  if ("bot_participation" in value) return record(value.bot_participation)
  const event = value.message_action ?? value.message_reaction
  if (!record(event) || !chat(event.chat) || !user(event.actor) || !integer(event.message_id)) return false
  if ("message_action" in value)
    return (
      integer(event.interaction_id) &&
      record(event.action) &&
      typeof event.action.action_id === "string" &&
      optionalString(event.action.callback_data) &&
      optionalString(event.action.callback_data_base64)
    )
  return [event.old_reaction, event.new_reaction].every(
    (items) => Array.isArray(items) && items.every((item) => record(item) && typeof item.emoji === "string"),
  )
}
