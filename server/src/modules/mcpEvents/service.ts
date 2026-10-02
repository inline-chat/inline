import { oauthConfig } from "@in/server/modules/oauth/config"
import { Encryption2 } from "@in/server/modules/encryption/encryption2"
import { OauthModel } from "@in/server/db/models/oauth"
import { authenticateEventToken, authorizeSelector, validateGrant } from "./authorization"
import { eventCatalog, parseSelector, sourceBucket } from "./catalog"
import { decodeCursor, encodeCursor, sameSecret, signingKey, subscriptionId } from "./crypto"
import { currentSequence, replayPosition } from "./source"
import { activeSubscriptions, readSubscription, saveSubscription, stopSubscription } from "./repository"
import { callbackTransport, callbackUrl, verifyCallback, type CallbackTransport } from "./webhook"
import { McpEventsError, invalidParams, type EventPrincipal } from "./types"

const record = (value: unknown): Record<string, unknown> => {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw invalidParams()
  return value as Record<string, unknown>
}
const string = (value: unknown): string => { if (typeof value !== "string" || value.length === 0) throw invalidParams(); return value }
const keys = (value: Record<string, unknown>, allowed: string[]) => { if (Object.keys(value).some((key) => !allowed.includes(key))) throw invalidParams() }

export async function executeEventMethod(principal: EventPrincipal, method: string, value: unknown, transport: CallbackTransport = callbackTransport): Promise<unknown> {
  const params = value == null ? {} : record(value)
  if (method === "events/list") {
    keys(params, ["cursor"])
    if (params["cursor"] != null) throw invalidParams()
    const scopes = new Set(principal.grant.scope.split(/\s+/))
    const chat = scopes.has("messages:read") && (principal.grant.allowDms || principal.grant.allowHomeThreads || principal.grant.spaceIds.length > 0)
    const space = scopes.has("spaces:read") && principal.grant.spaceIds.length > 0
    return { events: eventCatalog().filter((definition) => definition.name === "inline.update" ? chat || space : definition.name.startsWith("space.") ? space : chat) }
  }
  if (method === "events/status") {
    keys(params, ["chatId"])
    const selector = parseSelector("inline.update", { chatId: params["chatId"] })
    if (!("chatId" in selector)) throw invalidParams()
    await authorizeSelector(principal, "inline.update", selector)
    return { subscriptions: (await activeSubscriptions(principal.grant.id, selector.chatId)).map((row) => ({ id: row.id, name: row.name,
      refreshBefore: row.expiresAt.toISOString() })) }
  }
  if (method !== "events/subscribe" && method !== "events/unsubscribe" && method !== "events/cursor") throw new McpEventsError({ code: -32601, message: "Event method not found" })
  keys(params, method === "events/cursor" ? ["name", "arguments"] : method === "events/unsubscribe" ? ["name", "arguments", "delivery"] : ["name", "arguments", "delivery", "cursor", "ttlMs"])
  const name = string(params["name"])
  const selector = parseSelector(name, params["arguments"])
  const bucket = sourceBucket(name, selector, principal.grant.inlineUserId)
  const binding = { grantId: principal.grant.id, name, selector, bucket }
  if (method === "events/cursor") {
    await authorizeSelector(principal, name, selector)
    return { cursor: encodeCursor(binding, await currentSequence(bucket)) }
  }
  const delivery = record(params["delivery"])
  keys(delivery, method === "events/unsubscribe" ? ["mode", "url"] : ["mode", "url", "secret"])
  if (delivery["mode"] !== "webhook") throw new McpEventsError({ code: -32014, message: "Unsupported event delivery mode", data: { feature: "delivery.mode" } })
  const url = callbackUrl(delivery["url"]).href
  const id = subscriptionId(principal.grant.id, name, selector, url)
  if (method === "events/unsubscribe") {
    if (!await stopSubscription(id, principal.grant.id)) throw new McpEventsError({ code: -32011, message: "Subscription not found", data: { kind: "subscription" } })
    return {}
  }
  await authorizeSelector(principal, name, selector)
  const secret = string(delivery["secret"])
  signingKey(secret)
  const ttl = params["ttlMs"] === undefined ? 5 * 60_000 : params["ttlMs"] === null ? 24 * 60 * 60_000 : params["ttlMs"]
  if (typeof ttl !== "number" || !Number.isSafeInteger(ttl) || ttl <= 0) throw invalidParams()
  const ttlMs = Math.min(24 * 60 * 60_000, ttl)
  if (params["cursor"] !== undefined && params["cursor"] !== null && typeof params["cursor"] !== "string") throw invalidParams()
  const requestedSeq = typeof params["cursor"] === "string" ? decodeCursor(params["cursor"], binding) : undefined
  const existing = await readSubscription(id)
  const cachedVerification = existing && Date.now() - existing.verifiedAt.getTime() < 60_000 && sameSecret(Encryption2.decryptToString(existing.secretEncrypted), secret)
  const reauthorize = async () => { await authorizeSelector(await validateGrant(await OauthModel.getGrant(principal.grant.id)), name, selector) }
  if (!cachedVerification) await verifyCallback({ id, url, secret, beforeConnect: reauthorize }, transport)
  await reauthorize()
  const saved = await saveSubscription({ id, grantId: principal.grant.id, name, selector, callbackUrl: url, secret,
    expiresAt: new Date(Date.now() + ttlMs), verifiedAt: cachedVerification ? existing.verifiedAt : new Date(),
    readPosition: (seq, transaction) => replayPosition(bucket, seq, transaction), ...(requestedSeq === undefined ? {} : { requestedSeq }) })
  return { id, refreshBefore: saved.row.expiresAt.toISOString(), cursor: encodeCursor(binding, saved.row.cursorSeq), truncated: saved.truncated }
}

const json = (status: number, body: unknown) => Response.json(body, { status, headers: { "cache-control": "no-store" } })

export async function handleMcpEvents(request: Request, body: unknown, transport: CallbackTransport = callbackTransport): Promise<Response> {
  const expected = oauthConfig().internalSharedSecret
  if (!expected || !sameSecret(request.headers.get("x-inline-mcp-secret") ?? "", expected)) return json(401, { error: "unauthorized" })
  try {
    const input = record(body)
    keys(input, ["method", "params", "token"])
    const token = string(input["token"])
    if (token.length > 2048) throw invalidParams()
    const principal = await authenticateEventToken(token)
    return json(200, await executeEventMethod(principal, string(input["method"]), input["params"], transport))
  } catch (error) {
    if (error instanceof McpEventsError) return json(200, { error: { code: error.code, message: error.message,
      ...(error.data === undefined && error.reason === undefined ? {} : { data: error.data ?? { reason: error.reason } }) } })
    throw error
  }
}
