import { Method, type User } from "@inline-chat/realtime-sdk"

const DEFAULT_PROFILE_TTL_MS = 10 * 60_000
const DEFAULT_MAX_PROFILES = 5_000

export type InlineSenderProfile = {
  id: string
  firstName?: string
  lastName?: string
  username?: string
}

type CachedProfile = {
  profile: InlineSenderProfile
  expiresAt: number
}

type UserDirectoryClient = {
  invokeUncheckedRaw(method: Method, input: unknown): Promise<unknown>
}

type UserDirectoryOptions = {
  ttlMs?: number
  maxProfiles?: number
  now?: () => number
  onError?: (operation: string, error: unknown) => void
}

export class InlineUserDirectory {
  private readonly profiles = new Map<string, CachedProfile>()
  private readonly hydratedChats = new Map<string, number>()
  private readonly chatFetches = new Map<string, Promise<void>>()
  private directoryExpiresAt = 0
  private directoryFetch: Promise<void> | null = null
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
    const userId = params.userId.toString()
    const cached = this.getFresh(userId)
    if (hasDisplayIdentity(cached)) return cached

    if (params.direct) {
      await this.hydrateDirectory()
    } else {
      await this.hydrateChat(params.chatId)
      // Participant payloads can be partial (especially for reply threads), so
      // this deliberate extra directory fetch fills the miss. Both RPC paths
      // are TTL-cached and in-flight deduplicated to avoid a per-message fetch.
      if (!hasDisplayIdentity(this.getFresh(userId))) await this.hydrateDirectory()
    }

    const resolved = this.getFresh(userId)
    return hasDisplayIdentity(resolved) ? resolved : undefined
  }

  remember(users: readonly User[]): void {
    const expiresAt = this.now() + this.ttlMs
    for (const user of users) {
      const id = user.id?.toString()
      if (!id || id === "0") continue
      const previous = this.profiles.get(id)?.profile
      const profile: InlineSenderProfile = {
        id,
        ...readProfileField(user.firstName, previous?.firstName, "firstName"),
        ...readProfileField(user.lastName, previous?.lastName, "lastName"),
        ...readProfileField(user.username, previous?.username, "username"),
      }
      this.profiles.delete(id)
      this.profiles.set(id, { profile, expiresAt })
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

  private async hydrateChat(chatId: bigint): Promise<void> {
    const key = chatId.toString()
    const hydratedUntil = this.hydratedChats.get(key) ?? 0
    if (hydratedUntil > this.now()) {
      this.hydratedChats.delete(key)
      this.hydratedChats.set(key, hydratedUntil)
      return
    }
    this.hydratedChats.delete(key)
    const existing = this.chatFetches.get(key)
    if (existing) return existing

    const fetch = (async () => {
      const result = await this.client.invokeUncheckedRaw(Method.GET_CHAT_PARTICIPANTS, {
        oneofKind: "getChatParticipants",
        getChatParticipants: { chatId },
      })
      this.remember(readUsers(result, "getChatParticipants"))
      this.hydratedChats.delete(key)
      this.hydratedChats.set(key, this.now() + this.ttlMs)
      while (this.hydratedChats.size > this.maxProfiles) {
        const oldest = this.hydratedChats.keys().next().value
        if (oldest == null) break
        this.hydratedChats.delete(oldest)
      }
    })()
      .catch((error) => this.onError?.("getChatParticipants", error))
      .finally(() => this.chatFetches.delete(key))

    this.chatFetches.set(key, fetch)
    await fetch
  }

  private async hydrateDirectory(): Promise<void> {
    if (this.directoryExpiresAt > this.now()) return
    if (this.directoryFetch) return this.directoryFetch

    const fetch = (async () => {
      const result = await this.client.invokeUncheckedRaw(Method.GET_CHATS, {
        oneofKind: "getChats",
        getChats: {},
      })
      this.remember(readUsers(result, "getChats"))
      this.directoryExpiresAt = this.now() + this.ttlMs
    })()
      .catch((error) => this.onError?.("getChats", error))
      .finally(() => {
        this.directoryFetch = null
      })

    this.directoryFetch = fetch
    await fetch
  }
}

function hasDisplayIdentity(profile: InlineSenderProfile | undefined): profile is InlineSenderProfile {
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

function readUsers(result: unknown, kind: "getChatParticipants" | "getChats"): User[] {
  if (!result || typeof result !== "object") return []
  const record = result as Record<string, unknown>
  const payload = record[kind]
  if (!payload || typeof payload !== "object") return []
  const users = (payload as { users?: unknown }).users
  return Array.isArray(users) ? users as User[] : []
}
