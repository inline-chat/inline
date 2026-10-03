import { Method, ProtocolClientError, type User } from "@inline-chat/realtime-sdk"

const DEFAULT_PROFILE_TTL_MS = 10 * 60_000
const DEFAULT_MAX_PROFILES = 5_000
const MISSING_SENDER_REFRESH_MS = 1_000

export type InlineSenderProfile = {
  id: string
  firstName?: string
  lastName?: string
  username?: string
  bot?: boolean
}

export type InlineUserResolution = {
  profile?: InlineSenderProfile
  provenanceVerified: boolean
}

type CachedProfile = {
  profile: InlineSenderProfile
  expiresAt: number
  kindVerifiedUntil: number
}

type UserDirectoryClient = {
  invokeUncheckedRaw(method: Method, input: unknown, options?: { timeoutMs: number }): Promise<unknown>
}

type UserDirectoryOptions = {
  ttlMs?: number
  maxProfiles?: number
  now?: () => number
  onError?: (operation: string, error: unknown) => void
}

export class InlineUserDirectory {
  private readonly profiles = new Map<string, CachedProfile>()
  private readonly lookupTimeouts = new Map<Method, number>()
  private readonly hydratedChats = new Map<string, number>()
  private readonly chatFetches = new Map<string, Promise<boolean>>()
  private directoryExpiresAt = 0
  private directoryFetch: Promise<boolean> | null = null
  private readonly ttlMs: number
  private readonly maxProfiles: number
  private readonly now: () => number
  private readonly onError: ((operation: string, error: unknown) => void) | undefined

  constructor(
    private readonly client: UserDirectoryClient,
    options: UserDirectoryOptions = {},
  ) {
    this.ttlMs = options.ttlMs ?? DEFAULT_PROFILE_TTL_MS
    this.maxProfiles = options.maxProfiles ?? DEFAULT_MAX_PROFILES
    this.now = options.now ?? Date.now
    this.onError = options.onError
  }

  async resolve(params: { userId: bigint; chatId: bigint; direct: boolean }): Promise<InlineSenderProfile | undefined> {
    const cached = this.getFresh(params.userId.toString())
    if (hasDisplayIdentity(cached)) return cached
    return (await this.resolveWithProvenance(params)).profile
  }

  async resolveWithProvenance(
    params: { userId: bigint; chatId: bigint; direct: boolean },
  ): Promise<InlineUserResolution> {
    const userId = params.userId.toString()
    const cached = this.getFresh(userId)
    if (cached && this.hasVerifiedKind(userId) && (cached.bot === true || hasDisplayIdentity(cached))) {
      return { profile: cached, provenanceVerified: true }
    }

    if (params.direct) {
      await this.hydrateDirectory(userId)
      const resolved = this.getFresh(userId)
      return {
        ...(resolved && (hasDisplayIdentity(resolved) || resolved.bot != null) ? { profile: resolved } : {}),
        provenanceVerified: this.hasVerifiedKind(userId),
      }
    } else {
      await this.hydrateChat(params.chatId, userId)
      const participant = this.getFresh(userId)
      if (participant && this.hasVerifiedKind(userId) && (participant.bot === true || hasDisplayIdentity(participant))) {
        return {
          profile: participant,
          provenanceVerified: true,
        }
      }
      // Participant payloads can be partial (especially for reply threads), so
      // this deliberate extra directory fetch fills the miss. Both RPC paths
      // are TTL-cached and in-flight deduplicated to avoid a per-message fetch.
      await this.hydrateDirectory(userId)
      const resolved = this.getFresh(userId)
      return {
        ...(resolved && (hasDisplayIdentity(resolved) || resolved.bot != null) ? { profile: resolved } : {}),
        provenanceVerified: this.hasVerifiedKind(userId),
      }
    }
  }

  remember(users: readonly User[], authoritativeKind = false): void {
    const expiresAt = this.now() + this.ttlMs
    for (const user of users) {
      const id = user.id?.toString()
      if (!id || id === "0") continue
      const previousRecord = this.profiles.get(id)
      const previous = previousRecord?.profile
      const profile: InlineSenderProfile = {
        id,
        ...readProfileField(user.firstName, previous?.firstName, "firstName"),
        ...readProfileField(user.lastName, previous?.lastName, "lastName"),
        ...readProfileField(user.username, previous?.username, "username"),
        // Canonical encodeUser always emits true for bots, including min
        // profiles. Omission is human only in these authenticated directory
        // RPCs; arbitrary partial remembers retain the previous/unknown kind.
        ...readBooleanProfileField(authoritativeKind && user.bot == null ? false : user.bot, previous?.bot, "bot"),
      }
      const changedKind = typeof user.bot === "boolean" && user.bot !== previous?.bot
      const kindVerifiedUntil = authoritativeKind ? expiresAt : changedKind ? 0 : previousRecord?.kindVerifiedUntil ?? 0
      if (!authoritativeKind && changedKind) {
        this.hydratedChats.clear()
        this.directoryExpiresAt = 0
      }
      this.profiles.delete(id)
      this.profiles.set(id, { profile, expiresAt, kindVerifiedUntil })
    }
    let evicted = false
    while (this.profiles.size > this.maxProfiles) {
      const oldest = this.profiles.keys().next().value
      if (oldest == null) break
      this.profiles.delete(oldest)
      evicted = true
    }
    if (evicted) {
      this.hydratedChats.clear()
      this.directoryExpiresAt = 0
    }
  }

  private getFresh(userId: string): InlineSenderProfile | undefined {
    const cached = this.profiles.get(userId)
    if (!cached) return undefined
    if (cached.expiresAt <= this.now()) {
      this.profiles.delete(userId)
      return undefined
    }
    this.profiles.delete(userId)
    this.profiles.set(userId, cached)
    return cached.profile
  }

  private hasVerifiedKind(userId: string): boolean {
    const cached = this.profiles.get(userId)
    return Boolean(cached && cached.kindVerifiedUntil > this.now() && typeof cached.profile.bot === "boolean")
  }

  private hydrationIsFresh(expiresAt: number, userId: string): boolean {
    const now = this.now()
    // A successful collection fetch proves only the users it actually contains.
    // Keep positive profiles cheap, but let a held new/partial sender refresh
    // after one retry interval instead of waiting for the positive ten-minute TTL.
    // Derive the last fetch from the existing expiry; no separate negative cache.
    return expiresAt > now && (this.hasVerifiedKind(userId) || now < expiresAt - this.ttlMs + MISSING_SENDER_REFRESH_MS)
  }

  private async hydrateChat(chatId: bigint, userId: string): Promise<boolean> {
    const key = chatId.toString()
    const hydratedUntil = this.hydratedChats.get(key) ?? 0
    if (this.hydrationIsFresh(hydratedUntil, userId)) {
      this.hydratedChats.delete(key)
      this.hydratedChats.set(key, hydratedUntil)
      return true
    }
    this.hydratedChats.delete(key)
    const existing = this.chatFetches.get(key)
    if (existing) return existing

    const fetch = (async () => {
      const result = await this.invokeLookup(Method.GET_CHAT_PARTICIPANTS, {
        oneofKind: "getChatParticipants",
        getChatParticipants: { chatId },
      })
      this.remember(readUsers(result, "getChatParticipants"), true)
      this.hydratedChats.delete(key)
      this.hydratedChats.set(key, this.now() + this.ttlMs)
      while (this.hydratedChats.size > this.maxProfiles) {
        const oldest = this.hydratedChats.keys().next().value
        if (oldest == null) break
        this.hydratedChats.delete(oldest)
      }
      return true
    })()
      .catch((error) => {
        this.onError?.("getChatParticipants", error)
        return false
      })
      .finally(() => this.chatFetches.delete(key))

    this.chatFetches.set(key, fetch)
    return await fetch
  }

  private async invokeLookup(method: Method.GET_CHAT_PARTICIPANTS | Method.GET_CHATS, input: unknown): Promise<unknown> {
    const timeoutMs = this.lookupTimeouts.get(method) ?? 1_500
    try {
      return await this.client.invokeUncheckedRaw(method, input, { timeoutMs })
    } catch (error) {
      // Learn a budget for this RPC instead of permanently rejecting a healthy
      // but slower server. Keep the original SDK ceiling and only two entries.
      if (error instanceof ProtocolClientError && error.code === "timeout") {
        this.lookupTimeouts.set(method, Math.max(this.lookupTimeouts.get(method) ?? 0, Math.min(30_000, timeoutMs * 2)))
      }
      throw error
    }
  }

  private async hydrateDirectory(userId: string): Promise<boolean> {
    if (this.hydrationIsFresh(this.directoryExpiresAt, userId)) return true
    if (this.directoryFetch) return this.directoryFetch

    const fetch = (async () => {
      const result = await this.invokeLookup(Method.GET_CHATS, {
        oneofKind: "getChats",
        getChats: {},
      })
      this.remember(readUsers(result, "getChats"), true)
      this.directoryExpiresAt = this.now() + this.ttlMs
      return true
    })()
      .catch((error) => {
        this.onError?.("getChats", error)
        return false
      })
      .finally(() => {
        this.directoryFetch = null
      })

    this.directoryFetch = fetch
    return await fetch
  }
}

function hasDisplayIdentity(profile: InlineSenderProfile | undefined): boolean {
  return Boolean(profile?.firstName || profile?.lastName || profile?.username)
}

function readProfileField<K extends "firstName" | "lastName" | "username">(
  value: unknown,
  previous: string | undefined,
  key: K,
): Partial<Record<K, string>> {
  const normalized = typeof value === "string" ? value.trim() : ""
  const resolved = normalized || previous
  return resolved ? { [key]: resolved } as Record<K, string> : {}
}

function readBooleanProfileField<K extends "bot">(
  value: boolean | undefined,
  previous: boolean | undefined,
  key: K,
): Partial<Record<K, boolean>> {
  const resolved = value ?? previous
  return resolved == null ? {} : { [key]: resolved } as Record<K, boolean>
}

function readUsers(result: unknown, kind: "getChatParticipants" | "getChats"): User[] {
  if (!result || typeof result !== "object") return []
  const record = result as Record<string, unknown>
  const payload = record[kind]
  if (!payload || typeof payload !== "object") return []
  const users = (payload as { users?: unknown }).users
  return Array.isArray(users) ? users as User[] : []
}
