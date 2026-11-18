import { parseInlineId, type UserID } from "@inline/ids"
import {
  MemoryAuthSessionPersistence,
  type AuthSessionPersistence,
  type AuthSessionPersistenceLoadResult,
} from "./persistence"

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
  userId: UserID
}

export type AuthState = {
  status:
    | "hydrating"
    | "unauthenticated"
    | "authenticated"
    | "storageUnavailable"
    | "reauthRequired"
  storageStatus:
    | "hydrating"
    | "ready"
    | "unavailable"
    | "corrupt"
  token: string | null
  currentUserId: UserID | null
  userIdHint: UserID | null
  hasHydrated: boolean
}

export type AuthEvent =
  | { type: "login"; session: AuthSession }
  | { type: "logout" }
  | { type: "update"; state: AuthState }

export type AuthStoreOptions = {
  /** Explicit marker for core/worker owners that must never persist. */
  persistence?: "memory"
  storage?: AuthSessionPersistence
}

export class AuthStore {
  readonly events = new AsyncChannel<AuthEvent>()
  readonly ready: Promise<void>

  private readonly emitter = new Emitter<AuthState>()
  private readonly persistence: AuthSessionPersistence
  private readonly detachPersistence: () => void
  private persistenceQueue = Promise.resolve()
  private mutationRevision = 0
  private state: AuthState

  constructor(options?: AuthStoreOptions) {
    this.persistence =
      options?.storage ?? new MemoryAuthSessionPersistence()
    this.state = {
      status: "hydrating",
      storageStatus: "hydrating",
      token: null,
      currentUserId: null,
      userIdHint: null,
      hasHydrated: false,
    }
    this.detachPersistence =
      this.persistence.subscribe?.(() => {
        void this.refreshFromStorage()
      }) ?? (() => undefined)
    this.ready = this.hydrate()
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

  login(session: AuthSession): Promise<void> {
    if (!session.token) {
      throw new TypeError("Inline auth token must not be empty")
    }
    const userId = parseInlineId<"user">(session.userId, {
      positive: true,
    })
    if (userId == null) {
      throw new TypeError("Inline auth user ID must be positive")
    }
    const exactSession = { token: session.token, userId }
    const revision = ++this.mutationRevision
    this.state = {
      ...this.state,
      status: "authenticated",
      storageStatus: "hydrating",
      token: exactSession.token,
      currentUserId: exactSession.userId,
      userIdHint: exactSession.userId,
      hasHydrated: true,
    }
    this.emit({ type: "login", session: exactSession })
    return this.enqueuePersistence(
      () => this.persistence.save(exactSession),
      revision,
    )
  }

  logout(): Promise<void> {
    if (
      this.state.token == null &&
      this.state.currentUserId == null &&
      this.state.status === "unauthenticated"
    ) {
      return this.persistenceQueue
    }
    const revision = ++this.mutationRevision
    this.state = {
      ...this.state,
      status: "unauthenticated",
      storageStatus: "hydrating",
      token: null,
      currentUserId: null,
      userIdHint: null,
      hasHydrated: true,
    }
    this.emit({ type: "logout" })
    return this.enqueuePersistence(
      () => this.persistence.clear(),
      revision,
    )
  }

  async refreshFromStorage() {
    await this.persistenceQueue
    const revision = this.mutationRevision
    const result = await this.loadPersistence()
    if (revision !== this.mutationRevision) return
    this.applyPersistenceResult(result, true)
  }

  dispose() {
    this.detachPersistence()
    this.events.close()
  }

  private async hydrate() {
    const revision = this.mutationRevision
    const result = await this.loadPersistence()
    if (revision !== this.mutationRevision) {
      if (!this.state.hasHydrated) {
        this.state = { ...this.state, hasHydrated: true }
        this.emit({ type: "update", state: this.state })
      }
      return
    }
    this.applyPersistenceResult(result, false)
  }

  private async loadPersistence(): Promise<AuthSessionPersistenceLoadResult> {
    try {
      return await this.persistence.load()
    } catch {
      return { status: "unavailable" }
    }
  }

  private applyPersistenceResult(
    result: AuthSessionPersistenceLoadResult,
    emitLifecycle: boolean,
  ) {
    const wasLoggedIn = this.isLoggedIn()

    switch (result.status) {
      case "ready":
        this.state = result.session
          ? {
              status: "authenticated",
              storageStatus: "ready",
              token: result.session.token,
              currentUserId: result.session.userId,
              userIdHint: result.session.userId,
              hasHydrated: true,
            }
          : {
              status: "unauthenticated",
              storageStatus: "ready",
              token: null,
              currentUserId: null,
              userIdHint: null,
              hasHydrated: true,
            }
        break
      case "unavailable":
        if (result.session) {
          this.state = {
            status: "authenticated",
            storageStatus: "unavailable",
            token: result.session.token,
            currentUserId: result.session.userId,
            userIdHint: result.session.userId,
            hasHydrated: true,
          }
        } else if (wasLoggedIn) {
          this.state = {
            ...this.state,
            storageStatus: "unavailable",
            hasHydrated: true,
          }
        } else {
          this.state = {
            status: "storageUnavailable",
            storageStatus: "unavailable",
            token: null,
            currentUserId: null,
            userIdHint: result.userIdHint ?? null,
            hasHydrated: true,
          }
        }
        break
      case "corrupt":
        this.state = {
          status: "reauthRequired",
          storageStatus: "corrupt",
          token: null,
          currentUserId: null,
          userIdHint: result.userIdHint ?? null,
          hasHydrated: true,
        }
        break
    }

    const isLoggedIn = this.isLoggedIn()
    if (emitLifecycle && wasLoggedIn !== isLoggedIn) {
      if (isLoggedIn) {
        this.emit({
          type: "login",
          session: {
            token: this.state.token!,
            userId: this.state.currentUserId!,
          },
        })
      } else {
        this.emit({ type: "logout" })
      }
      return
    }
    this.emit({ type: "update", state: this.state })
  }

  private enqueuePersistence(
    operation: () => Promise<void>,
    revision: number,
  ) {
    const task = this.persistenceQueue.then(operation)
    this.persistenceQueue = task.then(
      () => {
        if (revision !== this.mutationRevision) return
        this.state = {
          ...this.state,
          storageStatus: "ready",
        }
        this.emit({ type: "update", state: this.state })
      },
      () => {
        if (revision !== this.mutationRevision) return
        this.state = {
          ...this.state,
          storageStatus: "unavailable",
        }
        this.emit({ type: "update", state: this.state })
      },
    )
    return this.persistenceQueue
  }

  private emit(event: AuthEvent) {
    this.emitter.emit(this.state)
    void this.events.send(event)
  }

}

export {
  BrowserAuthSessionPersistence,
  MemoryAuthSessionPersistence,
} from "./persistence"
export type {
  AuthSessionPersistence,
  AuthSessionPersistenceLoadResult,
} from "./persistence"
