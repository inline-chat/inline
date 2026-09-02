import * as Crypto from "expo-crypto"
import * as SecureStore from "expo-secure-store"

import type { InlineUser } from "@/api/auth"

const tokenKey = "inline.auth.token"
const userIdKey = "inline.auth.userId"
const userKey = "inline.auth.user"
const deviceIdKey = "inline.device.id"

export type AuthSession = {
  token: string
  userId: number
  user?: InlineUser
}

export async function loadSession(): Promise<AuthSession | null> {
  const token = await SecureStore.getItemAsync(tokenKey)
  const rawUserId = await SecureStore.getItemAsync(userIdKey)
  if (!token || !rawUserId) return null

  const userId = Number(rawUserId)
  if (!Number.isSafeInteger(userId) || userId <= 0 || !token.startsWith(`${userId}:`)) return null

  const rawUser = await SecureStore.getItemAsync(userKey).catch(() => null)
  const user = readCachedUser(rawUser, userId)
  // A concurrent replacement or logout invalidates this snapshot.
  if (await SecureStore.getItemAsync(tokenKey) !== token) return null
  return { token, userId, user }
}

let pendingWrite: Promise<void> = Promise.resolve()
function serializeWrite(operation: () => Promise<void>): Promise<void> {
  const next = pendingWrite.then(operation)
  pendingWrite = next.catch(() => undefined)
  return next
}

export function saveSession(session: AuthSession): Promise<void> {
  return serializeWrite(() => writeSession(session))
}

async function writeSession(session: AuthSession): Promise<void> {
  if (!session.token || !Number.isSafeInteger(session.userId) || session.userId <= 0 ||
      !session.token.startsWith(`${session.userId}:`)) {
    throw new Error("Invalid session")
  }

  // Publish the token last so an interrupted account replacement cannot pair
  // a new token with the previous account's identity.
  await SecureStore.deleteItemAsync(tokenKey)
  await SecureStore.setItemAsync(userIdKey, String(session.userId))
  const user = readCachedUser(session.user ? JSON.stringify(session.user) : null, session.userId)
  if (user) {
    await SecureStore.setItemAsync(userKey, JSON.stringify(user))
  } else {
    await SecureStore.deleteItemAsync(userKey)
  }
  await SecureStore.setItemAsync(tokenKey, session.token)
}

function readCachedUser(rawUser: string | null, userId: number): InlineUser | undefined {
  if (!rawUser) return undefined
  try {
    const user: unknown = JSON.parse(rawUser)
    if (!user || typeof user !== "object" || !("id" in user) || String(user.id) !== String(userId)) {
      return undefined
    }
    // Profile metadata is optional and must never become another account's
    // displayed identity or prevent a valid session from loading.
    const profile = user as Record<string, unknown>
    return {
      id: userId,
      firstName: typeof profile.firstName === "string" ? profile.firstName : undefined,
      lastName: typeof profile.lastName === "string" ? profile.lastName : undefined,
      username: typeof profile.username === "string" ? profile.username : undefined,
      email: typeof profile.email === "string" ? profile.email : undefined,
    }
  } catch {
    return undefined
  }
}

export function clearSession(): Promise<void> {
  return serializeWrite(async () => {
    const results = await Promise.allSettled([tokenKey, userIdKey, userKey].map((key) =>
      SecureStore.deleteItemAsync(key)))
    if (results.some((result) => result.status === "rejected")) {
      throw new Error("Your saved session could not be fully cleared.")
    }
  })
}

export async function getDeviceId(): Promise<string> {
  const existing = await SecureStore.getItemAsync(deviceIdKey)
  if (existing) return existing

  const id = Crypto.randomUUID()
  await SecureStore.setItemAsync(deviceIdKey, id)
  return id
}
