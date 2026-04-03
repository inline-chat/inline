type Listener<T> = (value: T) => void

type ChannelResolver<T> = (result: IteratorResult<T>) => void

class AsyncChannel<T> implements AsyncIterable<T> {
  private queue: T[] = []
  private resolvers: ChannelResolver<T>[] = []
  private closed = false

  async send(value: T) {
    if (this.closed) return
    const resolver = this.resolvers.shift()
    if (resolver) {
      resolver({ value, done: false })
      return
    }
    this.queue.push(value)
  }

  close() {
    if (this.closed) return
    this.closed = true
    for (const resolver of this.resolvers) {
      resolver({ value: undefined as T, done: true })
    }
    this.resolvers = []
    this.queue = []
  }

  [Symbol.asyncIterator](): AsyncIterator<T> {
    return {
      next: () => {
        if (this.queue.length > 0) {
          const value = this.queue.shift() as T
          return Promise.resolve({ value, done: false })
        }

        if (this.closed) {
          return Promise.resolve({ value: undefined as T, done: true })
        }

        return new Promise<IteratorResult<T>>((resolve) => {
          this.resolvers.push(resolve)
        })
      },
    }
  }
}

class Emitter<T> {
  private listeners = new Set<Listener<T>>()

  emit(value: T) {
    for (const listener of this.listeners) {
      listener(value)
    }
  }

  subscribe(listener: Listener<T>) {
    this.listeners.add(listener)
    return () => {
      this.listeners.delete(listener)
    }
  }
}

export type AuthSession = {
  token: string
  userId: number
}

export type AuthState = {
  token: string | null
  currentUserId: number | null
  hasHydrated: boolean
}

export type AuthEvent =
  | { type: "login"; session: AuthSession }
  | { type: "logout" }
  | { type: "update"; state: AuthState }

export type AuthStoreOptions = {
  storageKey?: string
}

type PersistedAuthState = {
  token?: string | null
  currentUserId?: number | null
  userId?: number | null
}

const DEFAULT_STORAGE_KEY = "auth-store"

const getStorage = () => {
  if (typeof window === "undefined") return null
  try {
    return window.localStorage
  } catch {
    return null
  }
}

const parseUserId = (value: string | null) => {
  if (value == null) return null
  const trimmed = value.trim()
  if (trimmed.length === 0) return null
  const parsed = Number(trimmed)
  if (!Number.isFinite(parsed)) return null
  return parsed
}

export class AuthStore {
  readonly events = new AsyncChannel<AuthEvent>()

  private readonly emitter = new Emitter<AuthState>()
  private readonly tokenStorageKey: string
  private readonly userIdStorageKey: string
  private readonly legacyStorageKey: string
  private state: AuthState

  constructor(options?: AuthStoreOptions) {
    const baseKey = options?.storageKey ?? DEFAULT_STORAGE_KEY
    this.legacyStorageKey = baseKey
    this.tokenStorageKey = `${baseKey}:token`
    this.userIdStorageKey = `${baseKey}:user-id`
    this.state = {
      token: null,
      currentUserId: null,
      hasHydrated: false,
    }

    this.hydrate()
  }

  subscribe(listener: (state: AuthState) => void) {
    return this.emitter.subscribe(listener)
  }

  getSnapshot = () => this.state

  getState() {
    return this.state
  }

  isLoggedIn() {
    return this.state.token != null && this.state.currentUserId != null
  }

  getToken() {
    return this.state.token
  }

  login(session: AuthSession) {
    this.state = {
      ...this.state,
      token: session.token,
      currentUserId: session.userId,
    }
    this.persist()
    this.emit({ type: "login", session })
  }

  logout() {
    if (this.state.token == null && this.state.currentUserId == null) return
    this.state = {
      ...this.state,
      token: null,
      currentUserId: null,
    }
    this.persist()
    this.emit({ type: "logout" })
  }

  private hydrate() {
    const storage = getStorage()
    if (!storage) {
      this.state = { ...this.state, hasHydrated: true }
      this.emit({ type: "update", state: this.state })
      return
    }

    let token = storage.getItem(this.tokenStorageKey)
    token = token && token.length > 0 ? token : null

    let currentUserId = parseUserId(storage.getItem(this.userIdStorageKey))

    if (!token && currentUserId == null) {
      const legacy = storage.getItem(this.legacyStorageKey)
      if (legacy) {
        try {
          const parsed = JSON.parse(legacy) as PersistedAuthState
          token = parsed.token ?? null
          const legacyUserId = parsed.currentUserId ?? parsed.userId ?? null
          currentUserId = typeof legacyUserId === "number" && Number.isFinite(legacyUserId) ? legacyUserId : null

          if (token) {
            storage.setItem(this.tokenStorageKey, token)
          }
          if (currentUserId != null) {
            storage.setItem(this.userIdStorageKey, String(currentUserId))
          }

          storage.removeItem(this.legacyStorageKey)
        } catch {
          // ignore malformed storage entries
        }
      }
    }

    this.state = {
      ...this.state,
      token: token ?? null,
      currentUserId: currentUserId ?? null,
      hasHydrated: true,
    }
    this.emit({ type: "update", state: this.state })
  }

  private persist() {
    const storage = getStorage()
    if (!storage) return

    try {
      if (this.state.token) {
        storage.setItem(this.tokenStorageKey, this.state.token)
      } else {
        storage.removeItem(this.tokenStorageKey)
      }

      if (this.state.currentUserId != null) {
        storage.setItem(this.userIdStorageKey, String(this.state.currentUserId))
      } else {
        storage.removeItem(this.userIdStorageKey)
      }
    } catch {
      // ignore storage errors
    }
  }

  private emit(event: AuthEvent) {
    this.emitter.emit(this.state)
    void this.events.send(event)
  }
}

export const auth = new AuthStore()
