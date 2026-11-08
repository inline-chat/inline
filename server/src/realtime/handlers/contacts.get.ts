import type { GetContactsInput, GetContactsResult } from "@inline-chat/protocol/core"
import { UsersModel } from "@in/server/db/models/users"
import { getContacts } from "@in/server/modules/contacts/contacts"
import { InMemoryRateLimiter } from "@in/server/modules/oauth/rateLimiter"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import type { HandlerContext } from "@in/server/realtime/types"

const contactsLimiter = new InMemoryRateLimiter({ capacity: 10_000 })

export async function getContactsHandler(
  input: GetContactsInput,
  context: HandlerContext,
): Promise<GetContactsResult> {
  const rate = contactsLimiter.consume({
    key: `get-contacts:${context.userId}`,
    nowMs: Date.now(),
    rule: { max: 60, windowMs: 60_000 },
  })
  if (!rate.allowed) throw RealtimeRpcError.RateLimit()

  const actor = await UsersModel.getUserById(context.userId)
  if (!actor || UsersModel.isDeleted(actor)) throw RealtimeRpcError.Unauthenticated()
  return getContacts(input, actor)
}
