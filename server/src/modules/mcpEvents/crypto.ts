import { createHash, createHmac, timingSafeEqual } from "node:crypto"
import { Encryption2 } from "@in/server/modules/encryption/encryption2"
import type { EventBucket, McpEventSelector } from "./types"
import { invalidParams } from "./types"

export const canonicalSelector = (selector: McpEventSelector): string => "chatId" in selector
  ? JSON.stringify({ chatId: selector.chatId, ...(selector.messageId !== undefined ? { messageId: selector.messageId } : {}),
    ...(selector.emoji !== undefined ? { emoji: selector.emoji } : {}), ...(selector.excludeSelf === true ? { excludeSelf: true } : {}) })
  : JSON.stringify({ spaceId: selector.spaceId })

export const subscriptionId = (grantId: string, name: string, selector: McpEventSelector, url: string): string =>
  `sub_${createHash("sha256").update(JSON.stringify([grantId, name, canonicalSelector(selector), url])).digest("hex")}`

export const sameSecret = (first: string, second: string): boolean => {
  const a = Buffer.from(first)
  const b = Buffer.from(second)
  return a.byteLength === b.byteLength && timingSafeEqual(a, b)
}

export function signingKey(secret: string): Buffer {
  if (!/^whsec_[A-Za-z0-9+/]+={0,2}$/.test(secret)) throw invalidParams()
  const encoded = secret.slice(6)
  const key = Buffer.from(encoded, "base64")
  if (key.byteLength < 24 || key.byteLength > 64 || key.toString("base64").replace(/=+$/, "") !== encoded.replace(/=+$/, "")) throw invalidParams()
  return key
}

export function signature(secret: string, eventId: string, unixSeconds: number, body: string): string {
  return `v1,${createHmac("sha256", signingKey(secret)).update(`${eventId}.${unixSeconds}.${body}`).digest("base64")}`
}

type CursorBinding = { grantId: string; name: string; selector: McpEventSelector; bucket: EventBucket }
export function encodeCursor(binding: CursorBinding, seq: number): string {
  return `mcpe1_${Encryption2.encrypt(Buffer.from(JSON.stringify({ v: 1, grant: binding.grantId, name: binding.name,
    selector: canonicalSelector(binding.selector), bucket: binding.bucket.kind, entity: binding.bucket.entityId, seq }))).toString("base64url")}`
}

export function decodeCursor(cursor: string, binding: CursorBinding): number {
  if (!/^mcpe1_[A-Za-z0-9_-]{1,2048}$/.test(cursor)) throw invalidParams()
  try {
    const value: unknown = JSON.parse(Encryption2.decryptToString(Buffer.from(cursor.slice(6), "base64url")))
    if (!value || typeof value !== "object") throw invalidParams()
    const record = value as Record<string, unknown>
    if (record["v"] !== 1 || record["grant"] !== binding.grantId || record["name"] !== binding.name ||
      record["selector"] !== canonicalSelector(binding.selector) || record["bucket"] !== binding.bucket.kind ||
      record["entity"] !== binding.bucket.entityId || typeof record["seq"] !== "number" || !Number.isSafeInteger(record["seq"]) ||
      record["seq"] < 0 || record["seq"] > 2_147_483_647) throw invalidParams()
    return record["seq"]
  } catch {
    throw invalidParams()
  }
}

export function occurrenceId(binding: CursorBinding, seq: number): string {
  return `evt_${createHash("sha256").update(JSON.stringify([binding.grantId, binding.name, canonicalSelector(binding.selector), binding.bucket.kind, binding.bucket.entityId, seq])).digest("hex")}`
}
