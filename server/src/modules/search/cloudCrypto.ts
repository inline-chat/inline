import { randomBytes } from "node:crypto"
import { db } from "@in/server/db"
import { chatSearchKeys } from "@in/server/db/schema"
import { eq } from "drizzle-orm"
import { isSealedContent, openContent, sealContent } from "@in/server/modules/encryption/contentEncryption"

export class CloudSearchCryptoError extends Error {
  constructor() {
    super("Cloud search cryptography failed")
    this.name = "CloudSearchCryptoError"
  }
}

const keyPurpose = (chatId: number) => `cloud-search/key/v1/${chatId}`

export async function ensureChatSearchKey(chatId: number): Promise<void> {
  const [existing] = await db
    .select({ chatId: chatSearchKeys.chatId })
    .from(chatSearchKeys)
    .where(eq(chatSearchKeys.chatId, chatId))
    .limit(1)
  if (existing) return
  const secret = randomBytes(32)
  try {
    await db
      .insert(chatSearchKeys)
      .values({
        chatId,
        keyEnvelope: sealContent(secret, keyPurpose(chatId)),
      })
      .onConflictDoNothing()
  } finally {
    secret.fill(0)
  }
}

export function openChatSearchKey(chatId: number, envelope: Uint8Array): Buffer {
  if (!Number.isSafeInteger(chatId) || chatId < 1 || !isSealedContent(envelope)) throw new CloudSearchCryptoError()
  const secret = openContent(envelope, keyPurpose(chatId))
  if (secret.length !== 32) {
    secret.fill(0)
    throw new CloudSearchCryptoError()
  }
  return secret
}

/** Cursor contents are authenticated ciphertext, never a client authorization grant. */
export function sealSearchCursor(value: object): string {
  return sealContent(Buffer.from(JSON.stringify(value)), "cloud-search/cursor/v1").toString("base64url")
}

export function openSearchCursor(value: string): unknown {
  try {
    if (value.length > 4096 || !/^[A-Za-z0-9_-]+$/.test(value)) throw new CloudSearchCryptoError()
    const bytes = Buffer.from(value, "base64url")
    if (bytes.toString("base64url") !== value || !isSealedContent(bytes)) throw new CloudSearchCryptoError()
    return JSON.parse(openContent(bytes, "cloud-search/cursor/v1").toString("utf8"))
  } catch {
    throw new CloudSearchCryptoError()
  }
}
