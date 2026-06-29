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
  if (!Number.isFinite(userId)) return null

  const rawUser = await SecureStore.getItemAsync(userKey)
  const user = rawUser ? (JSON.parse(rawUser) as InlineUser) : undefined
  return { token, userId, user }
}

export async function saveSession(session: AuthSession): Promise<void> {
  await SecureStore.setItemAsync(tokenKey, session.token)
  await SecureStore.setItemAsync(userIdKey, String(session.userId))
  if (session.user) {
    await SecureStore.setItemAsync(userKey, JSON.stringify(session.user))
  }
}

export async function clearSession(): Promise<void> {
  await SecureStore.deleteItemAsync(tokenKey)
  await SecureStore.deleteItemAsync(userIdKey)
  await SecureStore.deleteItemAsync(userKey)
}

export async function getDeviceId(): Promise<string> {
  const existing = await SecureStore.getItemAsync(deviceIdKey)
  if (existing) return existing

  const id = Crypto.randomUUID()
  await SecureStore.setItemAsync(deviceIdKey, id)
  return id
}
