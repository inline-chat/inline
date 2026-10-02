import { createHash } from "node:crypto"
import { eq } from "drizzle-orm"
import { db } from "@in/server/db"
import { chats } from "@in/server/db/schema"
import { OauthModel, type OauthGrant } from "@in/server/db/models/oauth"
import { Encryption2 } from "@in/server/modules/encryption/encryption2"
import { getUserIdFromToken, AuthTokenError } from "@in/server/modules/auth/sessionAuthentication"
import { AccessGuards } from "@in/server/modules/authorization/accessGuards"
import { getSpacePrivacyContext } from "@in/server/modules/privacy/spacePrivacy"
import { oauthConfig } from "@in/server/modules/oauth/config"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { sourceBucket } from "./catalog"
import { accessDenied, type EventPrincipal, type McpEventSelector } from "./types"

export async function validateGrant(grant: OauthGrant | null): Promise<EventPrincipal> {
  if (!grant || grant.revokedAtMs !== null || grant.resource !== oauthConfig().resource || !grant.inlineTokenEncrypted) throw accessDenied()
  let session: Awaited<ReturnType<typeof getUserIdFromToken>>
  try { session = await getUserIdFromToken(Encryption2.decryptToString(grant.inlineTokenEncrypted)) }
  catch (error) { if (error instanceof AuthTokenError) throw accessDenied(); throw error }
  if (session.userId !== grant.inlineUserId) throw accessDenied()
  return { grant, sessionId: session.sessionId }
}

export async function authenticateEventToken(token: string): Promise<EventPrincipal> {
  const result = await OauthModel.getGrantByActiveAccessTokenHash(createHash("sha256").update(token).digest("hex"), Date.now())
  return validateGrant(result?.grant ?? null)
}

/** Called at subscription creation, immediately before each connection, and before acknowledgement. */
export async function authorizeSelector(principal: EventPrincipal, name: string, selector: McpEventSelector) {
  const scopes = new Set(principal.grant.scope.split(/\s+/))
  if ("spaceId" in selector) {
    if (!scopes.has("spaces:read") || !principal.grant.spaceIds.some((value) => value.toString() === selector.spaceId)) throw accessDenied()
    try { await getSpacePrivacyContext(Number(selector.spaceId), principal.grant.inlineUserId) }
    catch (error) { if (error instanceof RealtimeRpcError) throw accessDenied(); throw error }
    return { bucket: sourceBucket(name, selector, principal.grant.inlineUserId), otherUserId: undefined }
  }
  if (!scopes.has("messages:read")) throw accessDenied()
  const [chat] = await db.select().from(chats).where(eq(chats.id, Number(selector.chatId))).limit(1)
  if (!chat) throw accessDenied()
  try { await AccessGuards.ensureChatAccess(chat, principal.grant.inlineUserId) }
  catch (error) { if (error instanceof RealtimeRpcError) throw accessDenied(); throw error }
  let owningChat = chat
  const visited = new Set<number>()
  while (owningChat.spaceId == null && owningChat.parentChatId != null) {
    if (visited.has(owningChat.id)) throw accessDenied()
    visited.add(owningChat.id)
    const [parent] = await db.select().from(chats).where(eq(chats.id, owningChat.parentChatId)).limit(1)
    if (!parent) throw accessDenied()
    owningChat = parent
  }
  if (owningChat.type === "private") {
    if (!principal.grant.allowDms) throw accessDenied()
  } else if (owningChat.spaceId == null) {
    if (!principal.grant.allowHomeThreads) throw accessDenied()
  } else if (!principal.grant.spaceIds.some((value) => value === BigInt(owningChat.spaceId!))) throw accessDenied()
  return { bucket: sourceBucket(name, selector, principal.grant.inlineUserId),
    otherUserId: chat.type === "private" ? (chat.minUserId === principal.grant.inlineUserId ? chat.maxUserId : chat.minUserId) ?? undefined : undefined }
}
