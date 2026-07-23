import { parseInlineId, type UserID } from "@inline/ids"
import type { AuthSession } from "./core"

export type AuthSessionPersistenceLoadResult =
  | {
      status: "ready"
      session: AuthSession | null
    }
  | {
      status: "unavailable"
      session?: AuthSession
      userIdHint?: UserID
    }
  | {
      status: "corrupt"
      userIdHint?: UserID
    }

export interface AuthSessionPersistence {
  load(): Promise<AuthSessionPersistenceLoadResult>
  save(session: AuthSession): Promise<void>
  clear(): Promise<void>
  subscribe?(listener: () => void): () => void
}

export class MemoryAuthSessionPersistence
  implements AuthSessionPersistence
{
  private session: AuthSession | null = null

  async load(): Promise<AuthSessionPersistenceLoadResult> {
    return { status: "ready", session: this.session }
  }

  async save(session: AuthSession) {
    this.session = session
  }

  async clear() {
    this.session = null
  }
}

type StoredAuthSession = {
  key: string
  version: 1
  token: string
  userId: string
}

type LegacyAuthState = {
  token?: unknown
  currentUserId?: unknown
  userId?: unknown
}

const DATABASE_NAME = "inline-auth-session"
const DATABASE_VERSION = 1
const STORE_NAME = "sessions"

const parseSession = (value: unknown): AuthSession | undefined => {
  if (!value || typeof value !== "object") return undefined
  const candidate = value as {
    token?: unknown
    userId?: unknown
  }
  const parsedUserId = parseInlineId<"user">(
    candidate.userId,
    { positive: true },
  )
  if (
    typeof candidate.token !== "string" ||
    candidate.token.length === 0 ||
    parsedUserId == null
  ) {
    return undefined
  }
  return { token: candidate.token, userId: parsedUserId }
}

const userIdHint = (value: unknown) => {
  if (!value || typeof value !== "object") return undefined
  return (
    parseInlineId<"user">(
      (value as { userId?: unknown }).userId,
      { positive: true },
    ) ?? undefined
  )
}

export class BrowserAuthSessionPersistence
  implements AuthSessionPersistence
{
  private database: Promise<IDBDatabase> | null = null
  private channel: BroadcastChannel | null = null
  private readonly legacyTokenKey: string
  private readonly legacyUserIdKey: string
  private readonly legacyRecordKey: string
  private readonly logoutPendingKey: string
  private readonly channelName: string

  constructor(private readonly key: string) {
    this.legacyTokenKey = `${key}:token`
    this.legacyUserIdKey = `${key}:user-id`
    this.legacyRecordKey = key
    this.logoutPendingKey = `${key}:logout-pending`
    this.channelName = `${key}:auth-session-changed`
  }

  async load(): Promise<AuthSessionPersistenceLoadResult> {
    if (this.hasLogoutTombstone()) {
      try {
        await this.deleteRecord()
        this.removeLogoutTombstone()
      } catch {
        // The non-secret tombstone remains authoritative on this origin.
      }
      this.clearLegacyCredentials()
      return { status: "ready", session: null }
    }

    try {
      const value = await this.readRecord()
      if (value != null) {
        const session = parseSession(value)
        if (session) return { status: "ready", session }

        const legacy = this.readLegacySession()
        if (legacy) {
          try {
            await this.writeRecord(legacy)
            this.clearLegacyCredentials()
            return { status: "ready", session: legacy }
          } catch {
            return { status: "unavailable", session: legacy }
          }
        }
        return {
          status: "corrupt",
          userIdHint: userIdHint(value),
        }
      }
    } catch {
      const legacy = this.readLegacySession()
      return {
        status: "unavailable",
        ...(legacy ? { session: legacy } : {}),
      }
    }

    const legacy = this.readLegacySession()
    if (!legacy) {
      this.clearLegacyCredentials()
      return { status: "ready", session: null }
    }

    try {
      await this.writeRecord(legacy)
      this.clearLegacyCredentials()
      return { status: "ready", session: legacy }
    } catch {
      return { status: "unavailable", session: legacy }
    }
  }

  async save(session: AuthSession) {
    await this.writeRecord(session)
    this.removeLogoutTombstone()
    this.clearLegacyCredentials()
    this.notifyChanged()
  }

  async clear() {
    this.writeLogoutTombstone()
    try {
      await this.deleteRecord()
      this.clearLegacyCredentials()
      this.removeLogoutTombstone()
      this.notifyChanged()
    } catch (error) {
      this.clearLegacyCredentials()
      this.notifyChanged()
      throw error
    }
  }

  subscribe(listener: () => void) {
    const channel = this.getChannel()
    if (!channel) return () => undefined
    const onMessage = () => listener()
    channel.addEventListener("message", onMessage)
    return () => channel.removeEventListener("message", onMessage)
  }

  private async readRecord(): Promise<unknown> {
    const database = await this.open()
    return await new Promise((resolve, reject) => {
      const transaction = database.transaction(
        STORE_NAME,
        "readonly",
      )
      const request = transaction
        .objectStore(STORE_NAME)
        .get(this.key)
      request.onsuccess = () => resolve(request.result)
      request.onerror = () => reject(request.error)
      transaction.onabort = () => reject(transaction.error)
    })
  }

  private async writeRecord(session: AuthSession) {
    const database = await this.open()
    await new Promise<void>((resolve, reject) => {
      const transaction = database.transaction(
        STORE_NAME,
        "readwrite",
      )
      const record: StoredAuthSession = {
        key: this.key,
        version: 1,
        token: session.token,
        userId: String(session.userId),
      }
      transaction.objectStore(STORE_NAME).put(record)
      transaction.oncomplete = () => resolve()
      transaction.onerror = () => reject(transaction.error)
      transaction.onabort = () => reject(transaction.error)
    })
  }

  private async deleteRecord() {
    const database = await this.open()
    await new Promise<void>((resolve, reject) => {
      const transaction = database.transaction(
        STORE_NAME,
        "readwrite",
      )
      transaction.objectStore(STORE_NAME).delete(this.key)
      transaction.oncomplete = () => resolve()
      transaction.onerror = () => reject(transaction.error)
      transaction.onabort = () => reject(transaction.error)
    })
  }

  private open() {
    if (this.database) return this.database
    const opening = new Promise<IDBDatabase>((resolve, reject) => {
      if (typeof indexedDB === "undefined") {
        reject(new Error("IndexedDB is unavailable"))
        return
      }
      const request = indexedDB.open(
        DATABASE_NAME,
        DATABASE_VERSION,
      )
      request.onupgradeneeded = () => {
        const database = request.result
        if (!database.objectStoreNames.contains(STORE_NAME)) {
          database.createObjectStore(STORE_NAME, {
            keyPath: "key",
          })
        }
      }
      request.onsuccess = () => {
        request.result.onversionchange = () => {
          request.result.close()
          if (this.database === opening) this.database = null
        }
        resolve(request.result)
      }
      request.onerror = () => reject(request.error)
      request.onblocked = () =>
        reject(new Error("Inline auth database upgrade blocked"))
    })
    this.database = opening
    void opening.catch(() => {
      if (this.database === opening) this.database = null
    })
    return opening
  }

  private readLegacySession(): AuthSession | undefined {
    const storage = this.localStorage()
    if (!storage) return undefined
    try {
      const split = parseSession({
        token: storage.getItem(this.legacyTokenKey),
        userId: storage.getItem(this.legacyUserIdKey),
      })
      if (split) return split

      const record = storage.getItem(this.legacyRecordKey)
      if (!record) return undefined
      const parsed = JSON.parse(record) as LegacyAuthState
      return parseSession({
        token: parsed.token,
        userId: parsed.currentUserId ?? parsed.userId,
      })
    } catch {
      return undefined
    }
  }

  private clearLegacyCredentials() {
    const storage = this.localStorage()
    if (!storage) return
    try {
      storage.removeItem(this.legacyTokenKey)
      storage.removeItem(this.legacyUserIdKey)
      storage.removeItem(this.legacyRecordKey)
    } catch {
      // IndexedDB remains canonical even if legacy cleanup is unavailable.
    }
  }

  private hasLogoutTombstone() {
    try {
      return (
        this.localStorage()?.getItem(this.logoutPendingKey) === "1"
      )
    } catch {
      return false
    }
  }

  private writeLogoutTombstone() {
    try {
      this.localStorage()?.setItem(this.logoutPendingKey, "1")
    } catch {
      // The IndexedDB delete remains the primary logout operation.
    }
  }

  private removeLogoutTombstone() {
    try {
      this.localStorage()?.removeItem(this.logoutPendingKey)
    } catch {
      // A stale tombstone is fail-closed and will retry deletion next load.
    }
  }

  private localStorage() {
    if (typeof window === "undefined") return null
    try {
      return window.localStorage
    } catch {
      return null
    }
  }

  private getChannel() {
    if (this.channel) return this.channel
    if (
      typeof window === "undefined" ||
      typeof BroadcastChannel === "undefined"
    ) {
      return null
    }
    try {
      this.channel = new BroadcastChannel(this.channelName)
      return this.channel
    } catch {
      return null
    }
  }

  private notifyChanged() {
    try {
      this.getChannel()?.postMessage({ type: "changed" })
    } catch {
      // Persistence is authoritative; tab refresh is an optimization.
    }
  }
}

export const createBrowserAuthSessionPersistence = (
  key: string,
) => new BrowserAuthSessionPersistence(key)
