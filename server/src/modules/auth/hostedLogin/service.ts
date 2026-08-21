import { and, eq, gt, isNull } from "drizzle-orm"
import { createHash, randomBytes, randomUUID } from "node:crypto"
import { db } from "@in/server/db"
import {
  inlineProtocolAuthKeys,
  loginTransactions,
  nativeAppAuthRequests,
  oauthAuthRequests,
  sessions,
  users,
  type HostedAuthClient,
} from "@in/server/db/schema"
import { API_BASE_URL } from "@in/server/env"
import { InlineError } from "@in/server/types/errors"
import { authorizeInlineProtocolKey } from "@in/server/modules/inlineProtocol/authorizeKey"
import { generateToken } from "@in/server/utils/auth"
import { encrypt } from "@in/server/modules/encryption/encryption"
import { Encryption2 } from "@in/server/modules/encryption/encryption2"

const LOGIN_TTL_MS = 10 * 60 * 1_000

export type AuthenticatedAccount = {
  userId: number
  method: "email" | "phone" | "google" | "apple"
}

const digest = (value: string): Buffer => createHash("sha256").update(value).digest()
const randomCapability = (): string => randomBytes(32).toString("base64url")
const verificationCode = (): string => {
  const value = randomBytes(3).readUIntBE(0, 3) % 1_000_000
  return value.toString().padStart(6, "0")
}

export async function beginInlineProtocolBrowserLogin(input: {
  authKeyId: Uint8Array
  client: HostedAuthClient
  now?: Date
}): Promise<{
  loginTransactionId: string
  browserUrl: string
  verificationCode: string
  expiresAt: Date
}> {
  if (input.authKeyId.length !== 8) throw new InlineError(InlineError.ApiError.UNAUTHORIZED)
  const now = input.now ?? new Date()
  const id = randomUUID()
  const capability = randomCapability()
  const code = verificationCode()
  const expiresAt = new Date(now.getTime() + LOGIN_TTL_MS)
  await db.transaction(async (tx) => {
    await tx.update(loginTransactions).set({
      status: "cancelled",
      cancelledAt: now,
    }).where(and(
      eq(loginTransactions.inlineProtocolAuthKeyId, Buffer.from(input.authKeyId)),
      eq(loginTransactions.status, "pending"),
    ))
    await tx.insert(loginTransactions).values({
      id,
      capabilityHash: digest(capability),
      status: "pending",
      targetKind: "inline_protocol_key",
      inlineProtocolAuthKeyId: Buffer.from(input.authKeyId),
      verificationCode: code,
      client: input.client,
      expiresAt,
    })
  })
  return {
    loginTransactionId: id,
    browserUrl: `${API_BASE_URL}/v1/auth/login?capability=${encodeURIComponent(capability)}`,
    verificationCode: code,
    expiresAt,
  }
}

export async function beginOAuthHostedLogin(input: {
  oauthAuthRequestId: string
  client: HostedAuthClient
  now?: Date
}): Promise<{ browserUrl: string; expiresAt: Date }> {
  const now = input.now ?? new Date()
  const capability = randomCapability()
  const expiresAt = new Date(now.getTime() + LOGIN_TTL_MS)
  await db.insert(loginTransactions).values({
    id: randomUUID(),
    capabilityHash: digest(capability),
    status: "pending",
    targetKind: "oauth_authorization",
    oauthAuthRequestId: input.oauthAuthRequestId,
    verificationCode: verificationCode(),
    client: input.client,
    expiresAt,
  })
  return {
    browserUrl: `${API_BASE_URL}/v1/auth/login?capability=${encodeURIComponent(capability)}`,
    expiresAt,
  }
}

export async function getHostedLoginByCapability(capability: string, now = new Date()) {
  if (capability.length < 32 || capability.length > 128) return undefined
  return (await db.select().from(loginTransactions).where(and(
    eq(loginTransactions.capabilityHash, digest(capability)),
    eq(loginTransactions.status, "pending"),
    gt(loginTransactions.expiresAt, now),
    isNull(loginTransactions.cancelledAt),
  )).limit(1))[0]
}

export async function completeHostedLogin(input: {
  transactionId: string
  account: AuthenticatedAccount
  ip?: string
  now?: Date
}): Promise<{ targetKind: "inline_protocol_key" | "oauth_authorization" | "native_app" }> {
  const now = input.now ?? new Date()
  return db.transaction(async (tx) => {
    const transaction = (await tx.select().from(loginTransactions).where(and(
      eq(loginTransactions.id, input.transactionId),
      eq(loginTransactions.status, "pending"),
      gt(loginTransactions.expiresAt, now),
      isNull(loginTransactions.cancelledAt),
    )).for("update").limit(1))[0]
    if (!transaction) throw new InlineError(InlineError.ApiError.UNAUTHORIZED)

    const claimed = await tx.update(loginTransactions).set({
      status: "claimed",
      claimedAt: now,
      userId: input.account.userId,
      authMethod: input.account.method,
    }).where(and(
      eq(loginTransactions.id, transaction.id),
      eq(loginTransactions.status, "pending"),
    )).returning({ id: loginTransactions.id })
    if (claimed.length !== 1) throw new InlineError(InlineError.ApiError.UNAUTHORIZED)

    if (transaction.targetKind === "inline_protocol_key" && transaction.inlineProtocolAuthKeyId) {
      await authorizeInlineProtocolKey({
        tx,
        authKeyId: transaction.inlineProtocolAuthKeyId,
        userId: input.account.userId,
        client: Object.fromEntries(
          Object.entries(transaction.client).filter((entry): entry is [string, string] => typeof entry[1] === "string"),
        ),
        ip: input.ip,
        now,
      })
    } else if (transaction.targetKind === "oauth_authorization" && transaction.oauthAuthRequestId) {
      // Transitional MCP bridge: the OAuth target, not the authentication
      // method, owns this backing session until MCP executes grant-aware calls.
      const { token, tokenHash } = await generateToken(input.account.userId)
      const personalData = encrypt(JSON.stringify({ deviceName: transaction.client.deviceName, ip: input.ip }))
      await tx.insert(sessions).values({
        userId: input.account.userId,
        tokenHash,
        personalDataEncrypted: personalData.encrypted,
        personalDataIv: personalData.iv,
        personalDataTag: personalData.authTag,
        clientType: "web",
        deviceId: transaction.client.deviceId ?? null,
        date: now,
        lastActive: now,
      })
      await tx.update(oauthAuthRequests).set({
        inlineUserId: input.account.userId,
        authMethod: input.account.method,
        inlineTokenEncrypted: Encryption2.encrypt(Buffer.from(token)),
      }).where(eq(oauthAuthRequests.id, transaction.oauthAuthRequestId))
    } else if (transaction.targetKind === "native_app" && transaction.nativeAppAuthRequestId) {
      await tx.update(nativeAppAuthRequests).set({
        userId: input.account.userId,
        authMethod: input.account.method,
        provenAt: now,
      }).where(eq(nativeAppAuthRequests.id, transaction.nativeAppAuthRequestId))
    } else {
      throw new InlineError(InlineError.ApiError.INTERNAL)
    }

    await tx.update(loginTransactions).set({
      status: "complete",
      completedAt: now,
    }).where(and(
      eq(loginTransactions.id, transaction.id),
      eq(loginTransactions.status, "claimed"),
    ))
    return { targetKind: transaction.targetKind as "inline_protocol_key" | "oauth_authorization" | "native_app" }
  })
}

export async function inlineProtocolBrowserLoginStatus(input: {
  transactionId: string
  authKeyId: Uint8Array
  now?: Date
}): Promise<
  | { kind: "pending" }
  | { kind: "cancelled" }
  | { kind: "authorized"; user: typeof users.$inferSelect; accountSessionId: number }
> {
  const now = input.now ?? new Date()
  const row = (await db.select({
    transaction: loginTransactions,
    user: users,
    accountSessionId: inlineProtocolAuthKeys.accountSessionId,
    keyUserId: inlineProtocolAuthKeys.userId,
  }).from(loginTransactions).leftJoin(users, eq(users.id, loginTransactions.userId)).leftJoin(
    inlineProtocolAuthKeys,
    eq(inlineProtocolAuthKeys.authKeyId, loginTransactions.inlineProtocolAuthKeyId),
  ).where(and(
    eq(loginTransactions.id, input.transactionId),
    eq(loginTransactions.inlineProtocolAuthKeyId, Buffer.from(input.authKeyId)),
  )).limit(1))[0]
  if (!row) throw new InlineError(InlineError.ApiError.UNAUTHORIZED)
  if (row.transaction.status === "complete" && row.user) {
    if (!row.accountSessionId || row.keyUserId !== row.user.id) {
      throw new InlineError(InlineError.ApiError.INTERNAL)
    }
    return { kind: "authorized", user: row.user, accountSessionId: row.accountSessionId }
  }
  if (row.transaction.status === "cancelled" || row.transaction.expiresAt <= now) return { kind: "cancelled" }
  return { kind: "pending" }
}
