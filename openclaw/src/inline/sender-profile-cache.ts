import type { User } from "@inline-chat/realtime-sdk"

const DEFAULT_PROFILE_TTL_MS = 10 * 60_000
const DEFAULT_MAX_PROFILES = 5_000

export type InlineSenderProfile = {
  name?: string
  username?: string
  bot?: boolean
}

export type InlineSenderProfileResolution = {
  profile?: InlineSenderProfile
  provenanceVerified: boolean
}

type CachedProfile = {
  firstName?: string
  lastName?: string
  username?: string
  bot?: boolean
  expiresAt: number
}

type InlineSenderProfileCacheOptions = {
  fetchChatParticipants: (chatId: bigint) => Promise<readonly User[]>
  fetchDirectoryUsers: () => Promise<readonly User[]>
  onError?: (operation: "getChatParticipants" | "getChats", error: unknown) => void
  ttlMs?: number
  maxProfiles?: number
  now?: () => number
}

export class InlineSenderProfileCache {
  private readonly profiles = new Map<string, CachedProfile>()
  private readonly hydratedChats = new Map<string, number>()
  private readonly participantFetches = new Map<string, Promise<boolean>>()
  private directoryExpiresAt = 0
  private directoryFetch: Promise<boolean> | null = null
  private readonly ttlMs: number
  private readonly maxProfiles: number
  private readonly now: () => number

  constructor(private readonly options: InlineSenderProfileCacheOptions) {
    this.ttlMs = options.ttlMs ?? DEFAULT_PROFILE_TTL_MS
    this.maxProfiles = options.maxProfiles ?? DEFAULT_MAX_PROFILES
    this.now = options.now ?? Date.now
  }

  get(userId: string): InlineSenderProfile | undefined {
    const cached = this.profiles.get(userId)
    if (!cached) return undefined
    if (cached.expiresAt <= this.now()) {
      this.profiles.delete(userId)
      return undefined
    }

    // Touch successful reads so the size bound evicts the least recently used profile.
    this.profiles.delete(userId)
    this.profiles.set(userId, cached)
    const name = [cached.firstName, cached.lastName].filter(Boolean).join(" ").trim()
    return {
      ...(name ? { name } : {}),
      ...(cached.username ? { username: cached.username } : {}),
      ...(cached.bot != null ? { bot: cached.bot } : {}),
    }
  }

  remember(users: readonly User[]): void {
    const expiresAt = this.now() + this.ttlMs
    for (const user of users) {
      const userId = String(user.id)
      if (!userId || userId === "0") continue

      const previous = this.profiles.get(userId)
      const profile: CachedProfile = {
        ...readProfileField(user.firstName, previous?.firstName, "firstName"),
        ...readProfileField(user.lastName, previous?.lastName, "lastName"),
        ...readProfileField(normalizeInlineUsername(user.username), previous?.username, "username"),
        ...readBooleanProfileField(user.bot, previous?.bot, "bot"),
        expiresAt,
      }
      this.profiles.delete(userId)
      this.profiles.set(userId, profile)
    }

    let evicted = false
    while (this.profiles.size > this.maxProfiles) {
      const oldest = this.profiles.keys().next().value
      if (oldest == null) break
      this.profiles.delete(oldest)
      evicted = true
    }
    if (evicted) {
      // An evicted profile must be fetchable again before the normal hydration TTL.
      this.hydratedChats.clear()
      this.directoryExpiresAt = 0
    }
  }

  async resolve(params: { userId: string; chatId: bigint }): Promise<InlineSenderProfile | undefined> {
    return (await this.resolveWithProvenance(params)).profile
  }

  async resolveWithProvenance(
    params: { userId: string; chatId: bigint },
  ): Promise<InlineSenderProfileResolution> {
    // OpenClaw uses the participant snapshot for history authors as well as the
    // current sender, so hydrate each chat even when this sender is known from
    // another conversation or the directory cache.
    const participantHydrated = await this.hydrateChatResult(params.chatId)
    const participant = this.get(params.userId)
    if (hasDisplayIdentity(participant)) {
      return {
        profile: participant,
        provenanceVerified: participantHydrated || participant.bot != null,
      }
    }

    // Reply-thread and minimized participant payloads can omit the actor. This
    // extra directory fetch is TTL-cached and in-flight deduplicated.
    const directoryHydrated = await this.hydrateDirectoryResult()
    const resolved = this.get(params.userId)
    return {
      ...(hasDisplayIdentity(resolved) ? { profile: resolved } : {}),
      provenanceVerified: directoryHydrated && (participantHydrated || hasDisplayIdentity(resolved)),
    }
  }

  async hydrateChat(chatId: bigint): Promise<void> {
    await this.hydrateChatResult(chatId)
  }

  private async hydrateChatResult(chatId: bigint): Promise<boolean> {
    const chatKey = String(chatId)
    const hydratedUntil = this.hydratedChats.get(chatKey) ?? 0
    if (hydratedUntil > this.now()) {
      this.hydratedChats.delete(chatKey)
      this.hydratedChats.set(chatKey, hydratedUntil)
      return true
    }
    this.hydratedChats.delete(chatKey)
    const existing = this.participantFetches.get(chatKey)
    if (existing) return existing

    const run = this.options.fetchChatParticipants(chatId)
      .then((users) => {
        this.remember(users)
        this.hydratedChats.delete(chatKey)
        this.hydratedChats.set(chatKey, this.now() + this.ttlMs)
        while (this.hydratedChats.size > this.maxProfiles) {
          const oldest = this.hydratedChats.keys().next().value
          if (oldest == null) break
          this.hydratedChats.delete(oldest)
        }
        return true
      })
      .catch((error) => {
        this.options.onError?.("getChatParticipants", error)
        return false
      })
      .finally(() => this.participantFetches.delete(chatKey))

    this.participantFetches.set(chatKey, run)
    return await run
  }

  async hydrateDirectory(): Promise<void> {
    await this.hydrateDirectoryResult()
  }

  private async hydrateDirectoryResult(): Promise<boolean> {
    if (this.directoryExpiresAt > this.now()) return true
    if (this.directoryFetch) return this.directoryFetch

    const run = this.options.fetchDirectoryUsers()
      .then((users) => {
        this.remember(users)
        this.directoryExpiresAt = this.now() + this.ttlMs
        return true
      })
      .catch((error) => {
        this.options.onError?.("getChats", error)
        return false
      })
      .finally(() => {
        this.directoryFetch = null
      })

    this.directoryFetch = run
    return await run
  }
}

function hasDisplayIdentity(profile: InlineSenderProfile | undefined): profile is InlineSenderProfile {
  return Boolean(profile?.name || profile?.username || profile?.bot != null)
}

function normalizeInlineUsername(value: string | undefined): string | undefined {
  const username = value?.trim().replace(/^@+/u, "")
  return username || undefined
}

function readProfileField<K extends "firstName" | "lastName" | "username">(
  value: string | undefined,
  previous: string | undefined,
  key: K,
): Partial<Record<K, string>> {
  const resolved = value?.trim() || previous
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
