import {
  DbObjectKind,
  type DbModel,
  type Message,
} from "./models"

/**
 * Removes owner-local overlays before any durable adapter encodes a model.
 * Every persistence engine must share this policy so switching adapters does
 * not change restart behavior.
 */
export const preparePersistedModel = <O extends DbModel>(
  object: O,
): O => {
  if (object.kind !== DbObjectKind.Message) return object
  const { reactionIntents: _reactionIntents, ...message } =
    object as Message
  return message as O
}
