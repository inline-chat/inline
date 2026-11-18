/**
 * The app's runtime: one `AppModel` and everything that lives beside it for
 * the page's life, wired to the platform. Framework-free and DOM-free: the
 * browser pieces (`window`, `history`, the platform) are injected by
 * `boot.ts`, and tests inject fakes.
 *
 * Per signed-in session it binds, and unbinds when the session ends: the
 * workspace to the session history (`bindWorkspaceToHistory`), the badge,
 * the `pagehide` flush, and the boot marks for "core ready" and "first
 * sidebar rows". It also remembers why the last account ended, so the
 * sign-in screen can say "You were signed out" when it happened elsewhere.
 *
 * With a boot snapshot (`boot-snapshot/README.md`) the first session starts
 * from it before the auth store has answered: the app model sees the
 * snapshot's user through `hintedAuthStore`, the session gets a store client
 * over a `DeferredEndpoint` with the snapshot restored, and the real
 * connector is called only once the auth store confirms the user. A
 * different answer tears the session down and erases the snapshot.
 */

import type { UserID } from "@inline/ids"
import type { Log } from "@inline/log"
import {
  computed,
  createStoreClient,
  effect,
  scope,
  signal,
  untracked,
  type Clock,
  type Dispose,
  type ReadSignal,
  type Scheduler,
} from "@inline/reactive"
import {
  bindWorkspaceToHistory,
  type ExternalOpener,
  type FocusRegion,
  type HistoryAdapter,
  type Platform as KeyboardPlatform,
  type StorageLike,
} from "@inline/view"
import {
  AppModel,
  type AccountConnection,
  type AccountConnector,
  type AccountSession,
  type AuthStoreLike,
  type SignInModelLike,
} from "@inline/view/features"
import {
  DeferredEndpoint,
  attachBootSnapshotSaver,
  eraseBootSnapshot,
  hintedAuthStore,
  provisionalData,
  type BootSnapshot,
  type BootSnapshotSaver,
  type SaveResult,
} from "./boot-snapshot"
import type { BootMetrics } from "./perf"
import { UnsavedWork } from "./unsaved-work"

/** The platform capabilities the runtime uses (`Platform` from `@inline/platform` fits). */
export type RuntimePlatform = {
  readonly badge: { set(count: number, options?: { immediate?: boolean }): void }
  readonly lifecycle: {
    onPageHide(listener: (event: { persisted: boolean }) => void): Dispose
    /** The page's visibility; the boot snapshot is saved when it turns hidden. */
    readonly visible?: ReadSignal<boolean>
  }
  readonly storage:
    | { readonly available: true; requestPersistence(): Promise<boolean> }
    | { readonly available: false }
}

/** Link roles (`LinkRole` from `@inline/link`), kept structural so the runtime does not import link. */
export type CoreRole = "connecting" | "leader" | "follower" | "handoff" | "superseded" | "closed"

type RoleSource = { readonly role?: CoreRole; onRole?(listener: (role: CoreRole) => void): () => void }

/**
 * The boot snapshot at this start: none read; `provisional` while the first
 * session paints from it and the auth store has not confirmed the user;
 * `confirmed` once it has (the core is connected); `discarded` when the auth
 * store said otherwise (the provisional session was torn down).
 */
export type BootSnapshotState = "none" | "provisional" | "confirmed" | "discarded"

export type BootSnapshotOptions = {
  /** What `readBootSnapshot` found, read synchronously by `boot.ts` before the runtime exists. */
  readonly initial?: BootSnapshot
  /** For the provisional session's store client (the frame lane) and for idle saves. */
  readonly scheduler: Scheduler
  /** Wall clock in milliseconds. Default `Date.now`. */
  readonly now?: () => number
  /** A precise clock for the cost of a save (`performance.now`). */
  readonly elapsed?: () => number
  readonly onSave?: (result: SaveResult) => void
}

/** What the chat pane reports about the chat it shows (`OpenChat` fits). */
export type OpenChatInfo = {
  readonly chatId: string
  /** How its first rows arrived: `memory`, `sqlite` or `network`; undefined until opened. */
  readonly source: ReadSignal<string | undefined>
}

/** Why the last account ended, for the sign-in screen. Undefined when the user signed out here. */
export type SignedOutReason = "elsewhere" | "revoked"

/** What the shell gives the runtime while it is mounted. */
export type ShellHooks = {
  readonly focusRegion: (region: FocusRegion) => void
  /** A character was typed outside any field: focus the composer of the focused pane. */
  readonly typeToFocus: () => void
  /** Focus left a removed element (a closed layer, a swapped chat): put it somewhere useful. */
  readonly restoreFocus: () => void
}

export type AppRuntimeOptions<S extends SignInModelLike> = {
  readonly authStore: AuthStoreLike
  /** Creates a sign-in model. `signOut` signs out from here (the model's back after authentication). */
  readonly createSignIn: (deps: { readonly signOut: () => Promise<unknown> }) => S
  readonly connect: AccountConnector
  readonly platform: RuntimePlatform
  readonly keyboardPlatform: KeyboardPlatform
  readonly clock: Clock
  readonly metrics: BootMetrics
  /** `localStorage`: workspaces and layouts, keyed by account. */
  readonly storage?: StorageLike
  readonly buildId?: string
  readonly protocol?: number
  /**
   * The session history to bind each workspace to (the browser's, wrapped by
   * `createSessionHistory`, whose `endSession` the runtime calls when an
   * account ends). Without it, nothing is bound.
   */
  readonly history?: () => HistoryAdapter & { endSession?(): void }
  /** Erase what the app keeps for an account outside the replica (service worker caches, layout). */
  readonly eraseAccountData?: (userId: UserID) => Promise<void>
  /** Sign out here: revoke on the server, then clear the auth store. Default `authStore.logout()`. */
  readonly signOut?: () => Promise<unknown>
  readonly opener?: ExternalOpener
  readonly log?: Log
  /**
   * More per-session wiring (notifications), run when a session starts and
   * undone when it ends. When `ownsBadge` is true it also keeps the badge, and
   * the runtime's own badge binding is skipped.
   */
  readonly attachSession?: {
    readonly ownsBadge?: boolean
    readonly attach: (session: AccountSession, context: { readonly role: ReadSignal<CoreRole | undefined> }) => Dispose
  }
  /**
   * The boot snapshot: paint the first session from `initial`, save while
   * signed in, erase on every end. Needs `storage` and `buildId`.
   */
  readonly bootSnapshot?: BootSnapshotOptions
  /**
   * A new account's setup stays on screen after the auth store signed it in
   * (Mac: profile setup before the main window). `held(signIn, userId)` says
   * whether the sign-in that just signed `userId` in must stay up (it may read
   * signals); `release` lets it go when the account ends first.
   */
  readonly signInHold?: {
    readonly held: (signIn: S, userId: UserID) => boolean
    readonly release: (signIn: S) => void
  }
}

/** A session started from the boot snapshot, waiting for the auth store. */
type Provisional = {
  readonly userId: UserID
  session: AccountSession | undefined
  attached: boolean
  /** The session ended before the auth store answered. */
  closed: boolean
  readonly attach: (token: string) => void
}

/** Layout storage key for an account (sidebar width and collapse). */
export const layoutStorageKey = (userId: UserID): string => `inline:layout:${userId}`

export class AppRuntime<S extends SignInModelLike = SignInModelLike> {
  readonly app: AppModel<S>
  readonly metrics: BootMetrics
  readonly unsavedWork = new UnsavedWork()
  /** The link role of the current account's core connection, where the connector reports one. */
  readonly role: ReadSignal<CoreRole | undefined>
  readonly signedOutReason: ReadSignal<SignedOutReason | undefined>
  /**
   * The last account's sign-out could not confirm its erase (`eraseFailed`,
   * or the core did not report within `SIGN_OUT_WAIT_MS`): the sign-in screen
   * says data may remain until the next start removes it. Cleared by the next
   * sign-in, the next end, or dismissing the notice.
   */
  readonly eraseIncomplete: ReadSignal<boolean>
  readonly storage: StorageLike | undefined
  /** What became of the boot snapshot at this start. */
  readonly bootSnapshot: ReadSignal<BootSnapshotState>
  /**
   * The sign-in to keep on screen over a started session: a new account's
   * setup (`signInHold`). The gate shows it instead of the shell while set.
   */
  readonly heldSignIn: ReadSignal<S | undefined>
  /** The chat each pane shows, by pane ID, for diagnostics and the automation snapshot. */
  readonly openChats = new Map<string, OpenChatInfo>()

  readonly #options: AppRuntimeOptions<S>
  readonly #role = signal<CoreRole | undefined>(undefined)
  readonly #signedOutReason = signal<SignedOutReason | undefined>(undefined)
  readonly #eraseIncomplete = signal(false)
  readonly #bootSnapshot = signal<BootSnapshotState>("none")
  /** The last sign-in the app model showed, while it may still be held. */
  readonly #lastSignIn = signal<S | undefined>(undefined)
  #stop: Dispose
  /** The snapshot the first session will start from, until its connection is made. */
  #pendingSnapshot: BootSnapshot | undefined
  #provisional: Provisional | undefined
  #saver: BootSnapshotSaver | undefined
  #shell: ShellHooks | undefined
  #signingOutHere = false
  #persistenceAsked = false
  #disposed = false

  constructor(options: AppRuntimeOptions<S>) {
    this.#options = options
    this.metrics = options.metrics
    this.storage = options.storage
    this.role = { get: () => this.#role.get(), peek: () => this.#role.peek() }
    this.signedOutReason = { get: () => this.#signedOutReason.get(), peek: () => this.#signedOutReason.peek() }
    this.eraseIncomplete = { get: () => this.#eraseIncomplete.get(), peek: () => this.#eraseIncomplete.peek() }
    this.bootSnapshot = { get: () => this.#bootSnapshot.get(), peek: () => this.#bootSnapshot.peek() }

    // A snapshot for a user the auth store already ruled out is erased unused.
    const initial = options.bootSnapshot && options.buildId !== undefined ? options.bootSnapshot.initial : undefined
    const known = options.authStore.getState()
    if (initial && known.hasHydrated && !(known.token && known.currentUserId === initial.user)) {
      eraseBootSnapshot(options.storage)
      this.#bootSnapshot.set("discarded")
    } else if (initial) {
      this.#pendingSnapshot = initial
      this.#bootSnapshot.set("provisional")
    }
    const authStore = this.#pendingSnapshot ? hintedAuthStore(options.authStore, this.#pendingSnapshot.user) : options.authStore

    const signOutHere = () => this.signOut()
    this.app = new AppModel<S>({
      authStore,
      createSignIn: () => options.createSignIn({ signOut: signOutHere }),
      session: {
        connect: (userId) => this.#connect(userId),
        clock: options.clock,
        ...(options.buildId !== undefined ? { buildId: options.buildId } : {}),
        ...(options.protocol !== undefined ? { protocol: options.protocol } : {}),
        ...(options.storage ? { storage: options.storage } : {}),
        ...(options.opener ? { opener: options.opener } : {}),
      },
      eraseAccountData: (userId) => this.#erase(userId),
      ...(options.signOut ? { signOut: options.signOut } : {}),
      platform: options.keyboardPlatform,
      onTypeToFocus: () => this.#shell?.typeToFocus(),
    })

    const hold = options.signInHold
    this.heldSignIn = computed(() => {
      const phase = this.app.phase.get()
      const signIn = this.#lastSignIn.get()
      if (!hold || !signIn || phase.kind !== "signedIn") return undefined
      return hold.held(signIn, phase.session.userId) ? signIn : undefined
    })

    this.#stop = scope(() => {
      let current: AccountSession | undefined
      effect(() => {
        const phase = this.app.phase.get()
        untracked(() => {
          if (phase.kind !== "booting") this.metrics.mark("gate")
          if (phase.kind === "signedOut") {
            const previous = this.#lastSignIn.peek()
            if (previous && previous !== phase.signIn) hold?.release(previous)
            this.#lastSignIn.set(phase.signIn)
          } else if (phase.kind === "signingOut") {
            // The account ended before its setup finished: let the sign-in go.
            const previous = this.#lastSignIn.peek()
            this.#lastSignIn.set(undefined)
            if (previous) hold?.release(previous)
          }
          if (phase.kind === "signedIn") {
            current = phase.session
            this.#signedOutReason.set(undefined)
            this.#eraseIncomplete.set(false)
            this.#signingOutHere = false
          } else if (phase.kind === "signingOut" && current) {
            const ended = current
            current = undefined
            // A session the auth store never confirmed was not signed out of: nothing to say.
            const unconfirmed = this.#provisional?.session === ended
            this.#signedOutReason.set(
              this.#signingOutHere || unconfirmed ? undefined : ended.revoked.peek() ? "revoked" : "elsewhere",
            )
            this.#signingOutHere = false
            this.#eraseIncomplete.set(false)
            this.#resetLocation()
            this.#followErase(ended)
          }
        })
      })
      effect(() => {
        const session = this.app.session.get()
        if (!session) return
        return untracked(() => this.#wireSession(session))
      })
    })
    // The real auth store, not the hinted one: it confirms or rules out a provisional session.
    const stopConfirming = options.authStore.subscribe(() => this.#confirmProvisional())
    const stopEffects = this.#stop
    this.#stop = () => {
      stopConfirming()
      stopEffects()
    }
  }

  /** The last boot snapshot save of this page (diagnostics). */
  get lastSnapshotSave(): SaveResult | undefined {
    return this.#saver?.last
  }

  /** Sign out from this tab. The gate returns to sign-in without a "signed out elsewhere" notice. */
  signOut(): Promise<unknown> {
    if (this.app.phase.peek().kind === "signedIn") this.#signingOutHere = true
    return this.app.signOut()
  }

  /** The shell attaches its focus hooks while mounted. Returns the detach function. */
  attachShell(hooks: ShellHooks): () => void {
    this.#shell = hooks
    return () => {
      if (this.#shell === hooks) this.#shell = undefined
    }
  }

  /** Focus left a removed element; the shell decides where it goes. */
  restoreFocus(): void {
    this.#shell?.restoreFocus()
  }

  dismissSignedOutReason(): void {
    this.#signedOutReason.set(undefined)
    this.#eraseIncomplete.set(false)
  }

  /**
   * The address bar after an account ends: the app's root. The next account
   * must not open the last one's destination (`/c/<id>/m/<id>`), which the
   * history binding would read as a deep link when the next session starts;
   * nor reach it with Back: the history's session ends, so every earlier
   * entry reads as `/`. The account's stored workspace is cleared by
   * `AccountSession.end`.
   */
  #resetLocation(): void {
    const history = this.#options.history?.()
    if (!history) return
    try {
      // A new history session: Back and Forward to the ended account's entries read as `/` (`history-session.ts`).
      if (history.endSession) history.endSession()
      else if (history.current().path !== "/") history.replace("/", null)
    } catch {
      // A history the page may not write (sandboxed): nothing to reset.
    }
  }

  /** Record whether the ended account's erase was confirmed (`AccountSession.end`'s outcome). */
  #followErase(session: AccountSession): void {
    // The app model calls `end({ erase: true })` right after entering `signingOut`; a later call returns that promise.
    void Promise.resolve()
      .then(() => session.end({ erase: true }))
      .then((outcome) => {
        this.#options.log?.info("sign-out", { outcome })
        if (this.#disposed || this.app.phase.peek().kind === "signedIn") return
        if (outcome === "eraseFailed" || outcome === "timedOut") this.#eraseIncomplete.set(true)
      })
  }

  /** Resolves once an ending account has been torn down. */
  idle(): Promise<void> {
    return this.app.idle()
  }

  dispose(): void {
    if (this.#disposed) return
    this.#disposed = true
    this.#stop()
    this.app.dispose()
    const signIn = this.#lastSignIn.peek()
    this.#lastSignIn.set(undefined)
    if (signIn) this.#options.signInHold?.release(signIn)
  }

  #connect(userId: UserID): AccountConnection {
    const snapshot = this.#pendingSnapshot
    this.#pendingSnapshot = undefined
    const boot = this.#options.bootSnapshot
    if (snapshot && boot && snapshot.user === userId) return this.#connectProvisional(userId, snapshot, boot.scheduler)
    if (snapshot) {
      // Another user signed in before the first session started.
      eraseBootSnapshot(this.#options.storage)
      this.#bootSnapshot.set("discarded")
    }
    return this.#connectNow(userId)
  }

  #connectNow(userId: UserID): AccountConnection {
    const connection = this.#options.connect(userId)
    const source = connection.core as unknown as RoleSource
    let stopRole: (() => void) | undefined
    if (typeof source.onRole === "function") {
      this.#role.set(source.role)
      stopRole = source.onRole((role) => this.#role.set(role))
    } else {
      this.#role.set(undefined)
    }
    return {
      core: connection.core,
      client: connection.client,
      close: () => {
        stopRole?.()
        stopRole = undefined
        this.#role.set(undefined)
        connection.close()
      },
    }
  }

  /**
   * The first session's connection when it starts from the boot snapshot: a
   * store client over a deferred endpoint, with the snapshot to restore. The
   * real connector is called by `#confirmProvisional`, once the auth store
   * confirms this user, never before the session has its provisional state.
   */
  #connectProvisional(userId: UserID, snapshot: BootSnapshot, scheduler: Scheduler): AccountConnection {
    const deferred = new DeferredEndpoint()
    const client = createStoreClient({ endpoint: deferred, scheduler })
    let real: AccountConnection | undefined
    const provisional: Provisional = {
      userId,
      session: undefined,
      attached: false,
      closed: false,
      attach: (token) => {
        if (provisional.closed || real) return
        real = this.#connectNow(userId)
        // The session reads through the client above; the connector's own is not used.
        real.client.dispose()
        provisional.attached = true
        deferred.attach(real.core, { userId, token })
      },
    }
    this.#provisional = provisional
    return {
      core: deferred,
      client,
      provisional: provisionalData(snapshot),
      close: () => {
        // `#provisional` stays until the auth store answers (`#confirmProvisional`).
        provisional.closed = true
        client.dispose()
        deferred.close()
        real?.close()
      },
    }
  }

  /** The real auth store answered (or the session started): connect, or let the app model tear down. */
  #confirmProvisional(): void {
    const provisional = this.#provisional
    if (!provisional || provisional.attached || !provisional.session) return
    const state = this.#options.authStore.getState()
    if (!state.hasHydrated) return
    this.#provisional = undefined
    if (state.token && state.currentUserId === provisional.userId && !provisional.closed) {
      provisional.attach(state.token)
      this.#bootSnapshot.set("confirmed")
      return
    }
    // The app model got the same answer first and has ended the session.
    this.#bootSnapshot.set("discarded")
    eraseBootSnapshot(this.#options.storage)
  }

  async #erase(userId: UserID): Promise<void> {
    try {
      this.#options.storage?.removeItem(layoutStorageKey(userId))
    } catch {
      // Storage may be unavailable; the layout is not sensitive.
    }
    // Message text, names and the sidebar: erased on every end of an account.
    eraseBootSnapshot(this.#options.storage)
    await this.#options.eraseAccountData?.(userId)
  }

  #wireSession(session: AccountSession): Dispose {
    const { platform, metrics, log } = { platform: this.#options.platform, metrics: this.metrics, log: this.#options.log }
    const disposers: (() => void)[] = []
    log?.info("session started")

    const provisional = this.#provisional
    if (provisional && !provisional.session && provisional.userId === session.userId) {
      provisional.session = session
      // An auth store that had already answered (the demo) confirms now.
      this.#confirmProvisional()
    }

    const history = this.#options.history?.()
    if (history) {
      const binding = bindWorkspaceToHistory(session.workspace, history)
      session.setHistory(binding)
      disposers.push(() => {
        session.setHistory(undefined)
        binding.dispose()
      })
    }

    const extra = this.#options.attachSession
    const ownBadge = !extra?.ownsBadge
    disposers.push(
      scope(() => {
        let first = true
        if (ownBadge) {
          effect(() => {
            const count = session.badgeCount.get()
            untracked(() => platform.badge.set(count, first ? { immediate: true } : {}))
            first = false
          })
        }
        effect(() => {
          if (session.coreResource.get()?.phase === "ready") untracked(() => metrics.mark("coreReady"))
        })
        effect(() => {
          if (session.sidebar.items.get().length > 0) untracked(() => metrics.markAfterPaint("sidebarRows"))
        })
        if (session.restoredFromSnapshot) {
          // Every list restored from the snapshot has been answered by the core.
          effect(() => {
            if (session.client.store.provisionalSubs.get().size === 0) {
              untracked(() => metrics.markAfterPaint("snapshotReconciled"))
            }
          })
        }
      }),
    )

    disposers.push(
      platform.lifecycle.onPageHide(() => {
        this.unsavedWork.flush()
        session.flush()
      }),
    )

    const boot = this.#options.bootSnapshot
    const buildId = this.#options.buildId
    if (boot && buildId !== undefined) {
      const saver = attachBootSnapshotSaver({
        session,
        storage: this.#options.storage,
        buildId,
        clock: this.#options.clock,
        idle: (task) => boot.scheduler.idle(task),
        onPageHide: (listener) => platform.lifecycle.onPageHide(() => listener()),
        ...(platform.lifecycle.visible ? { visible: platform.lifecycle.visible } : {}),
        ...(boot.now ? { now: boot.now } : {}),
        ...(boot.elapsed ? { elapsed: boot.elapsed } : {}),
        onSave: (result) => {
          if ("erased" in result) log?.info("boot snapshot erased", { reason: result.reason })
          else log?.info("boot snapshot saved", { reason: result.reason, chars: result.chars, ms: result.ms })
          boot.onSave?.(result)
        },
      })
      this.#saver = saver
      disposers.push(() => saver.dispose())
    }

    if (extra) {
      try {
        disposers.push(extra.attach(session, { role: this.role }))
      } catch (error) {
        log?.error("session wiring failed", { error })
      }
    }

    if (!this.#persistenceAsked && platform.storage.available) {
      this.#persistenceAsked = true
      // Eviction would drop unsent intents; ask where the browser does not prompt.
      void platform.storage.requestPersistence().catch(() => false)
    }

    return () => {
      for (const dispose of disposers.splice(0).reverse()) dispose()
      if (ownBadge) platform.badge.set(0, { immediate: true })
      log?.info("session ended")
    }
  }
}
