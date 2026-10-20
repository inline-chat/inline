import { and, eq, gt, isNull, or } from "drizzle-orm"
import { createHash, createHmac, randomBytes, randomUUID } from "node:crypto"
import { isIP } from "node:net"
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
import { authorizeInlineProtocolKey, finishInlineProtocolSessionReplacement } from "@in/server/modules/inlineProtocol/authorizeKey"
import type { SessionReplacement } from "@in/server/db/models/sessions"
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

/**
 * A keyed fingerprint of the client's network: the full IPv4 address, or the
 * /64 for IPv6 (temporary addresses rotate within it). Used only to tell the
 * person confirming a CLI login whether it started on their own network.
 */
export function networkFingerprint(ip: string | undefined): string | undefined {
  if (!ip || isIP(ip) === 0) return undefined
  const network = isIP(ip) === 6 && !ip.toLowerCase().startsWith("::ffff:")
    ? expandIpv6(ip).slice(0, 4).join(":")
    : ip.toLowerCase().replace(/^::ffff:/, "")
  return createHmac("sha256", process.env["ENCRYPTION_KEY"] ?? "inline-login-network")
    .update(`login-network-v1:${network}`)
    .digest("base64url")
    .slice(0, 22)
}

function expandIpv6(ip: string): string[] {
  const [head = "", tail = ""] = ip.toLowerCase().split("%", 1)[0]!.split("::")
  const left = head ? head.split(":") : []
  const right = tail ? tail.split(":") : []
  const fill = ip.includes("::") ? Array<string>(Math.max(0, 8 - left.length - right.length)).fill("0") : []
  return [...left, ...fill, ...right].map((part) => part.padStart(4, "0"))
}

/**
 * Records which account proved itself for a CLI login without authorizing the
 * CLI yet. The person must still confirm the code shown in their terminal.
 *
 * The browser link's capability is a bearer secret the CLI owner also holds
 * (their terminal printed it). Proof rotates it, and only the proving browser
 * receives the replacement, so a phisher's copy of the link can no longer
 * reach the confirmation step. Returns the new capability, or undefined when
 * the transaction is no longer pending for this account.
 */
export async function markHostedLoginProven(input: {
  transactionId: string
  account: AuthenticatedAccount
  now?: Date
}): Promise<string | undefined> {
  const now = input.now ?? new Date()
  const capability = randomCapability()
  const updated = await db.update(loginTransactions).set({
    userId: input.account.userId,
    authMethod: input.account.method,
    capabilityHash: digest(capability),
    browserCsrfHash: null,
  }).where(and(
    eq(loginTransactions.id, input.transactionId),
    eq(loginTransactions.status, "pending"),
    eq(loginTransactions.targetKind, "inline_protocol_key"),
    gt(loginTransactions.expiresAt, now),
    isNull(loginTransactions.cancelledAt),
    or(isNull(loginTransactions.userId), eq(loginTransactions.userId, input.account.userId)),
  )).returning({ id: loginTransactions.id })
  return updated.length === 1 ? capability : undefined
}

export async function cancelHostedLogin(transactionId: string, now = new Date()): Promise<void> {
  await db.update(loginTransactions).set({ status: "cancelled", cancelledAt: now }).where(and(
    eq(loginTransactions.id, transactionId),
    eq(loginTransactions.status, "pending"),
  ))
}

/** Issues a fresh browser CSRF value for a pending transaction. */
export async function issueHostedLoginCsrf(transactionId: string): Promise<string> {
  const csrf = randomBytes(32).toString("base64url")
  await db.update(loginTransactions).set({
    browserCsrfHash: createHash("sha256").update(csrf).digest(),
  }).where(and(eq(loginTransactions.id, transactionId), eq(loginTransactions.status, "pending")))
  return csrf
}

export async function getHostedLoginById(transactionId: string) {
  return (await db.select().from(loginTransactions).where(eq(loginTransactions.id, transactionId)).limit(1))[0]
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
  const completed = await db.transaction(async (tx) => {
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

    let replacement: SessionReplacement | undefined
    if (transaction.targetKind === "inline_protocol_key" && transaction.inlineProtocolAuthKeyId) {
      const authorized = await authorizeInlineProtocolKey({
        tx,
        authKeyId: transaction.inlineProtocolAuthKeyId,
        userId: input.account.userId,
        client: Object.fromEntries(
          Object.entries(transaction.client).filter((entry): entry is [string, string] => typeof entry[1] === "string"),
        ),
        ip: input.ip,
        now,
      })
      replacement = authorized.replacement
    } else if (transaction.targetKind === "oauth_authorization" && transaction.oauthAuthRequestId) {
      // Transitional MCP bridge: the OAuth target, not the authentication
      // method, owns this backing session until MCP executes grant-aware calls.
      const { token, tokenHash } = await generateToken(input.account.userId)
      const personalData = encrypt(JSON.stringify({
        deviceName: transaction.client.deviceName,
        ip: input.ip,
        signupAttribution: {
          ...transaction.client.signupAttribution,
          entryPoint: "oauth",
          oauthClient: transaction.client.deviceName,
          authMethod: input.account.method,
        },
      }))
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
    return { targetKind: transaction.targetKind as "inline_protocol_key" | "oauth_authorization" | "native_app", replacement }
  })
  await finishInlineProtocolSessionReplacement(completed.replacement)
  return { targetKind: completed.targetKind }
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
