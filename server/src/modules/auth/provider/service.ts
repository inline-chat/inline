import { Apple, generateCodeVerifier, Google } from "arctic"
import { eq } from "drizzle-orm"
import { randomBytes, randomUUID, createHash } from "node:crypto"
import { db } from "@in/server/db"
import { ProviderAuthModel } from "@in/server/db/models/providerAuth"
import {
  users,
  type AccountProvider,
  type DbProviderAuthAttempt,
  type ProviderAuthClient,
  type ProviderAuthPurpose,
} from "@in/server/db/schema"
import { encodeFullUserInfo } from "@in/server/api-types"
import { SessionsModel } from "@in/server/db/models/sessions"
import { Encryption2 } from "@in/server/modules/encryption/encryption2"
import { getOrCreateUserByEmailForSignup } from "@in/server/modules/auth/signupInvites"
import { normalizeAuthClientType } from "@in/server/modules/auth/clientType"
import { generateToken } from "@in/server/utils/auth"
import { validateIanaTimezone, validateUpToFourSegementSemver } from "@in/server/utils/validate"
import { InlineError } from "@in/server/types/errors"
import { providerAuthConfig } from "./config"
import { verifyAppleIdToken, verifyGoogleIdToken, type ProviderClaims } from "./claims"
import { fetchBinary } from "@inline-chat/url-preview"
import { uploadPhoto } from "@in/server/modules/files/uploadPhoto"
import { getFileByUniqueId } from "@in/server/db/models/files"
import { toArrayBufferBackedBytes } from "@in/server/utils/arrayBuffer"
import { Log } from "@in/server/utils/log"
import { createAppCodeChallenge, isValidAppCodeVerifier } from "./appHandoff"
import { applyAppleAuthorizationParameters } from "./authorizationUrl"

const config = providerAuthConfig()
const log = new Log("providerAuth")

export type ProviderLoginResult = {
  userId: number
  token: string
  user: ReturnType<typeof encodeFullUserInfo>
}

export type ProviderCallbackOutcome =
  | { kind: "login"; attempt: DbProviderAuthAttempt; result: ProviderLoginResult }
  | { kind: "invite" | "email"; attempt: DbProviderAuthAttempt; continuation: string }

export function hashProviderSecret(value: string): string {
  return createHash("sha256").update(value).digest("hex")
}

export function supportedAppCallbackScheme(value: string | null): value is string {
  return value !== null && ["in", "inline", "inline-dev", "inline-debug", "inline-debug-2"].includes(value)
}

export async function beginProviderAuth(input: {
  provider: AccountProvider
  purpose: ProviderAuthPurpose
  appCallbackScheme?: string
  appCodeChallenge?: string
  oauthAuthRequestId?: string
  client: ProviderAuthClient
}): Promise<URL> {
  if (input.purpose === "app" && (!input.appCallbackScheme || !input.appCodeChallenge)) {
    throw new Error("App provider sign-in requires a callback scheme and code challenge")
  }
  if (input.provider === "google" && !config.google) throw new ProviderUnavailableError("google")
  if (input.provider === "apple" && !config.apple) throw new ProviderUnavailableError("apple")
  const state = randomSecret()
  const nonce = randomSecret()
  const verifier = input.provider === "google" ? generateCodeVerifier() : undefined
  const id = randomUUID()

  await ProviderAuthModel.createAttempt({
    id,
    provider: input.provider,
    purpose: input.purpose,
    stateHash: hashProviderSecret(state),
    nonceHash: hashProviderSecret(nonce),
    nonceEncrypted: Encryption2.encrypt(Buffer.from(nonce)),
    pkceVerifierEncrypted: verifier ? Encryption2.encrypt(Buffer.from(verifier)) : undefined,
    appCallbackScheme: input.appCallbackScheme,
    appCodeChallenge: input.appCodeChallenge,
    oauthAuthRequestId: input.oauthAuthRequestId,
    client: input.client,
    expiresAt: new Date(Date.now() + config.attemptTtlMs),
  })

  const redirectUri = callbackUrl(input.provider)
  if (input.provider === "google") {
    if (!config.google || !verifier) throw new ProviderUnavailableError("google")
    const provider = new Google(config.google.clientId, config.google.clientSecret, redirectUri)
    const url = provider.createAuthorizationURL(state, verifier, ["openid", "email", "profile"])
    url.searchParams.set("nonce", nonce)
    url.searchParams.set("prompt", "select_account")
    return url
  }

  if (!config.apple) throw new ProviderUnavailableError("apple")
  const provider = new Apple(
    config.apple.clientId,
    config.apple.teamId,
    config.apple.keyId,
    config.apple.privateKey,
    redirectUri,
  )
  const url = provider.createAuthorizationURL(state, ["name", "email"])
  applyAppleAuthorizationParameters(url, nonce)
  return url
}

export async function completeProviderCallback(input: {
  provider: AccountProvider
  state: string
  code: string
  idTokenFromAuthorization?: string
  appleUserJson?: string
}): Promise<ProviderCallbackOutcome> {
  const attempt = await ProviderAuthModel.claimActiveByStateHash(
    hashProviderSecret(input.state),
    input.provider,
    hashProviderSecret(randomSecret()),
  )
  if (!attempt || attempt.provider !== input.provider || attempt.status !== "pending_provider") {
    throw new Error("Provider sign-in attempt is invalid or expired")
  }

  const nonce = recoverNonce(attempt)
  const claims = await exchangeAndVerify(input, attempt, nonce)
  const subjectHash = hashProviderSecret(`${claims.provider}\0${claims.subject}`)
  const existingUserId = await ProviderAuthModel.findIdentity(claims.provider, subjectHash)
  if (existingUserId) {
    const result = await createProviderSession(existingUserId, attempt.client)
    const updated = await storeCompletedAttempt(attempt, result)
    return { kind: "login", attempt: updated, result }
  }

  if (!claims.authoritativeEmail || !claims.email) {
    const continuation = randomSecret()
    const updated = await ProviderAuthModel.transition(attempt.id, "pending_provider", {
      status: "pending_email",
      continuationHash: hashProviderSecret(continuation),
      subjectHash,
      pendingProfileEncrypted: encryptClaims({ ...claims, email: undefined }),
    })
    return { kind: "email", attempt: updated, continuation }
  }

  return resolveTrustedClaims(attempt, claims, subjectHash)
}

export async function continueProviderWithInvite(input: {
  attemptId: string
  continuation: string
  inviteCode: string
}): Promise<{ attempt: DbProviderAuthAttempt; result: ProviderLoginResult }> {
  const attempt = await claimContinuation(input.attemptId, input.continuation, "pending_invite")
  try {
    const claims = decryptClaims(attempt)
    if (!claims.email || !claims.authoritativeEmail || !attempt.subjectHash) {
      throw new Error("Provider signup data is unavailable")
    }
    const outcome = await resolveTrustedClaims(attempt, claims, attempt.subjectHash, input.inviteCode)
    if (outcome.kind !== "login") throw new Error("Invite code did not complete provider signup")
    return { attempt: outcome.attempt, result: outcome.result }
  } catch (cause) {
    if (isRetryableInviteFailure(cause)) {
      await ProviderAuthModel.restoreContinuationClaim({
        id: attempt.id,
        status: "pending_invite",
        continuationHash: hashProviderSecret(input.continuation),
      })
    }
    throw cause
  }
}

export async function requireProviderEmailAttempt(
  attemptId: string,
  continuation: string,
): Promise<DbProviderAuthAttempt> {
  return requireContinuation(attemptId, continuation, "pending_email")
}

export async function claimProviderEmailAttempt(
  attemptId: string,
  continuation: string,
): Promise<DbProviderAuthAttempt> {
  return claimContinuation(attemptId, continuation, "pending_email")
}

export async function restoreProviderEmailAttempt(
  attemptId: string,
  continuation: string,
): Promise<boolean> {
  return ProviderAuthModel.restoreContinuationClaim({
    id: attemptId,
    status: "pending_email",
    continuationHash: hashProviderSecret(continuation),
  })
}

export async function attachProviderAfterEmailVerification(input: {
  attempt: DbProviderAuthAttempt
  result: ProviderLoginResult
}): Promise<DbProviderAuthAttempt> {
  if (!input.attempt.subjectHash) throw new Error("Provider identity is unavailable")
  const userId = await ProviderAuthModel.attachIdentity({
    provider: input.attempt.provider,
    subjectHash: input.attempt.subjectHash,
    userId: input.result.userId,
  })
  if (userId !== input.result.userId) {
    throw new Error("Provider identity belongs to another Inline account")
  }
  await applyProviderProfile(userId, decryptClaims(input.attempt))
  return storeCompletedAttempt(input.attempt, input.result)
}

export async function redeemProviderTicket(
  ticket: string,
  appCodeVerifier: string,
): Promise<ProviderLoginResult | undefined> {
  if (!isValidAppCodeVerifier(appCodeVerifier)) return undefined
  const attempt = await ProviderAuthModel.consumeTicket(
    hashProviderSecret(ticket),
    createAppCodeChallenge(appCodeVerifier),
  )
  if (!attempt?.inlineUserId || !attempt.inlineTokenEncrypted) return undefined
  const user = await loadActiveProviderUser(attempt.inlineUserId)
  return {
    userId: attempt.inlineUserId,
    token: Encryption2.decryptToString(attempt.inlineTokenEncrypted),
    user: encodeFullUserInfo(user),
  }
}

export async function issueAppTicket(attempt: DbProviderAuthAttempt): Promise<string> {
  if (attempt.purpose !== "app" || !attempt.appCallbackScheme || !attempt.appCodeChallenge) {
    throw new Error("Attempt is not an app sign-in")
  }
  const ticket = randomSecret()
  await ProviderAuthModel.update(attempt.id, { ticketHash: hashProviderSecret(ticket) })
  return ticket
}

async function exchangeAndVerify(
  input: { provider: AccountProvider; code: string; idTokenFromAuthorization?: string; appleUserJson?: string },
  attempt: DbProviderAuthAttempt,
  nonce: string,
): Promise<ProviderClaims> {
  if (input.provider === "google") {
    if (!config.google || !attempt.pkceVerifierEncrypted) throw new ProviderUnavailableError("google")
    const provider = new Google(config.google.clientId, config.google.clientSecret, callbackUrl("google"))
    const tokens = await provider.validateAuthorizationCode(
      input.code,
      Encryption2.decryptToString(attempt.pkceVerifierEncrypted),
    )
    return verifyGoogleIdToken({ idToken: tokens.idToken(), clientId: config.google.clientId, nonce })
  }

  if (!config.apple) throw new ProviderUnavailableError("apple")
  const provider = new Apple(
    config.apple.clientId,
    config.apple.teamId,
    config.apple.keyId,
    config.apple.privateKey,
    callbackUrl("apple"),
  )
  const tokens = await provider.validateAuthorizationCode(input.code)
  const appleUser = parseAppleUser(input.appleUserJson)
  return verifyAppleIdToken({
    idToken: input.idTokenFromAuthorization || tokens.idToken(),
    clientId: config.apple.clientId,
    nonce,
    firstName: appleUser?.name?.firstName,
    lastName: appleUser?.name?.lastName,
  })
}

async function resolveTrustedClaims(
  attempt: DbProviderAuthAttempt,
  claims: ProviderClaims,
  subjectHash: string,
  inviteCode?: string,
): Promise<ProviderCallbackOutcome> {
  try {
    const { user } = await getOrCreateUserByEmailForSignup(claims.email!, inviteCode)
    const ownerId = await ProviderAuthModel.attachIdentity({ provider: claims.provider, subjectHash, userId: user.id })
    await applyProviderProfile(ownerId, claims)
    const result = await createProviderSession(ownerId, attempt.client)
    const updated = await storeCompletedAttempt(attempt, result)
    return { kind: "login", attempt: updated, result }
  } catch (error) {
    if (!(error instanceof InlineError) || error.type !== InlineError.ApiError.INVITE_CODE_REQUIRED[0]) {
      throw error
    }
    const continuation = randomSecret()
    const updated = await ProviderAuthModel.transition(attempt.id, attempt.status, {
      status: "pending_invite",
      continuationHash: hashProviderSecret(continuation),
      subjectHash,
      pendingProfileEncrypted: encryptClaims(claims),
    })
    return { kind: "invite", attempt: updated, continuation }
  }
}

async function createProviderSession(userId: number, client: ProviderAuthClient): Promise<ProviderLoginResult> {
  const user = await loadActiveProviderUser(userId)
  const clientType = normalizeAuthClientType(client.clientType, "providerSignIn") ?? "web"
  const { token, tokenHash } = await generateToken(userId)
  await SessionsModel.create({
    userId,
    tokenHash,
    deviceId: client.deviceId,
    personalData: {
      deviceName: client.deviceName,
      timezone: client.timezone && validateIanaTimezone(client.timezone) ? client.timezone : undefined,
    },
    clientType,
    clientVersion: client.clientVersion && validateUpToFourSegementSemver(client.clientVersion)
      ? client.clientVersion
      : undefined,
    osVersion: client.osVersion && validateUpToFourSegementSemver(client.osVersion) ? client.osVersion : undefined,
  })
  return { userId, token, user: encodeFullUserInfo(user) }
}

async function applyProviderProfile(userId: number, claims: ProviderClaims): Promise<void> {
  const [user] = await db.select().from(users).where(eq(users.id, userId)).limit(1)
  if (!user) throw new Error("Provider user does not exist")
  const values = {
    firstName: user.firstName || claims.firstName || null,
    lastName: user.lastName || claims.lastName || null,
  }
  if (values.firstName !== user.firstName || values.lastName !== user.lastName) {
    await db.update(users).set(values).where(eq(users.id, userId))
  }
  if (!user.photoFileId && claims.photoUrl) {
    await importProviderPhoto(userId, claims.photoUrl).catch((cause) => {
      log.warn("Provider profile photo import failed", { userId, provider: claims.provider, cause })
    })
  }
}

async function importProviderPhoto(userId: number, photoUrl: string): Promise<void> {
  const image = await fetchBinary(photoUrl, {
    timeoutMs: 7_500,
    maxRedirects: 1,
    maxBytes: 1 * 1024 * 1024,
    allowedContentTypes: ["image/jpeg", "image/png", "image/webp"],
  })
  if (!image) return
  const finalUrl = new URL(image.finalUrl)
  if (
    finalUrl.protocol !== "https:" ||
    !(finalUrl.hostname === "googleusercontent.com" || finalUrl.hostname.endsWith(".googleusercontent.com"))
  ) return
  const extension = image.contentType === "image/png" ? "png" : image.contentType === "image/webp" ? "webp" : "jpg"
  const file = new File([toArrayBufferBackedBytes(image.bytes)], `provider-profile.${extension}`, {
    type: image.contentType,
  })
  const uploaded = await uploadPhoto(file, { userId })
  const dbFile = await getFileByUniqueId(uploaded.fileUniqueId)
  if (dbFile) {
    await db.update(users).set({ photoFileId: dbFile.id }).where(eq(users.id, userId))
  }
}

async function storeCompletedAttempt(
  attempt: DbProviderAuthAttempt,
  result: ProviderLoginResult,
): Promise<DbProviderAuthAttempt> {
  return ProviderAuthModel.transition(attempt.id, attempt.status, {
    status: "complete",
    continuationHash: null,
    inlineUserId: result.userId,
    inlineTokenEncrypted: Encryption2.encrypt(Buffer.from(result.token)),
  })
}

async function requireContinuation(
  attemptId: string,
  continuation: string,
  status: "pending_invite" | "pending_email",
): Promise<DbProviderAuthAttempt> {
  const attempt = await ProviderAuthModel.getActive(attemptId)
  if (!attempt || attempt.status !== status || attempt.continuationHash !== hashProviderSecret(continuation)) {
    throw new Error("Provider continuation is invalid or expired")
  }
  return attempt
}

async function claimContinuation(
  attemptId: string,
  continuation: string,
  status: "pending_invite" | "pending_email",
): Promise<DbProviderAuthAttempt> {
  const attempt = await ProviderAuthModel.claimContinuation({
    id: attemptId,
    status,
    continuationHash: hashProviderSecret(continuation),
  })
  if (!attempt) throw new Error("Provider continuation is invalid, expired, or already in use")
  return attempt
}

async function loadFullUser(userId: number) {
  const user = await db.query.users.findFirst({ where: { id: userId }, with: { photoFile: true } })
  if (!user) throw new Error("Provider user does not exist")
  return { ...user, photo: user.photoFile }
}

async function loadActiveProviderUser(userId: number) {
  const user = await loadFullUser(userId)
  if (user.deleted === true) {
    throw new InlineError(InlineError.ApiError.USER_DEACTIVATED)
  }
  return user
}

function isRetryableInviteFailure(cause: unknown): boolean {
  if (!(cause instanceof InlineError)) return false
  return cause.type === InlineError.ApiError.INVITE_CODE_REQUIRED[0] ||
    cause.type === InlineError.ApiError.INVITE_CODE_INVALID[0] ||
    cause.type === InlineError.ApiError.INVITE_CODE_NOT_FOUND[0] ||
    cause.type === InlineError.ApiError.INVITE_CODE_TAKEN[0]
}

function encryptClaims(claims: ProviderClaims): Buffer {
  return Encryption2.encrypt(Buffer.from(JSON.stringify(claims)))
}

function decryptClaims(attempt: DbProviderAuthAttempt): ProviderClaims {
  if (!attempt.pendingProfileEncrypted) throw new Error("Provider profile is unavailable")
  return JSON.parse(Encryption2.decryptToString(attempt.pendingProfileEncrypted)) as ProviderClaims
}

function callbackUrl(provider: AccountProvider): string {
  return `${config.baseUrl}/v1/auth/provider/callback/${provider}`
}

function randomSecret(): string {
  return randomBytes(32).toString("base64url")
}

// The raw nonce is recoverable only from the encrypted attempt payload and is checked against
// its separately stored hash before it is used for provider-token verification.
function recoverNonce(attempt: DbProviderAuthAttempt): string {
  const nonce = Encryption2.decryptToString(attempt.nonceEncrypted)
  if (attempt.nonceHash === hashProviderSecret(nonce)) return nonce
  throw new Error("Provider nonce is unavailable")
}

function parseAppleUser(value: string | undefined): { name?: { firstName?: string; lastName?: string } } | undefined {
  if (!value) return undefined
  try {
    return JSON.parse(value) as { name?: { firstName?: string; lastName?: string } }
  } catch {
    return undefined
  }
}

export class ProviderUnavailableError extends Error {
  constructor(readonly provider: AccountProvider) {
    super(`${provider} sign-in is not configured`)
  }
}
