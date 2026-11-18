/**
 * The top of the model tree. Follows the auth store:
 *
 * - `booting` until the stored session has been read;
 * - `signedOut` with a sign-in model when there is no session;
 * - `signedIn` with an `AccountSession` while there is one;
 * - `signingOut` while an ended account is torn down and erased.
 *
 * An account ends when the auth store loses its session: a sign-out here, a
 * sign-out in another tab (the auth store's persistence broadcasts it), or
 * the core reporting the session revoked (this model then clears the auth
 * store, which takes the same path). Ending disposes the session, asks the
 * core to sign out, runs the injected erase hook, then shows sign-in.
 */

import type { UserID } from "@inline/ids"
import { effect, scope, signal, untracked, type Dispose, type ReadSignal } from "@inline/reactive"
import { KeyboardDispatcher } from "../commands/keyboard"
import type { KeyEventLike } from "../commands/shortcut"
import type { Platform } from "../commands/platform"
import { CommandRegistry } from "../commands/registry"
import { AccountSession, type AccountSessionOptions } from "./account-session"

/**
 * The part of `AuthStore` (`@inline/auth`) this model reads. Kept structural
 * so the view package does not depend on the auth package's storage code.
 */
export type AuthStateLike = {
  readonly token: string | null
  readonly currentUserId: UserID | null
  readonly hasHydrated: boolean
}

export type AuthStoreLike = {
  getState(): AuthStateLike
  subscribe(listener: (state: AuthStateLike) => void): () => void
  logout(): Promise<void>
}

/** A sign-in model (`createSignInModel` from `@inline/auth/flows`), disposed if it can be. */
export type SignInModelLike = { dispose?(): void }

export type AppPhase<S extends SignInModelLike = SignInModelLike> =
  | { readonly kind: "booting" }
  | { readonly kind: "signedOut"; readonly signIn: S }
  | { readonly kind: "signedIn"; readonly session: AccountSession }
  | { readonly kind: "signingOut"; readonly userId: UserID }

export type AppModelOptions<S extends SignInModelLike> = {
  readonly authStore: AuthStoreLike
  /** Creates the sign-in model each time the app shows sign-in. */
  readonly createSignIn: () => S
  /** Everything an account session needs besides the user, the token and the registry. */
  readonly session: Omit<AccountSessionOptions, "userId" | "token" | "registry">
  /**
   * Erases what the app keeps for an account outside the core's replica
   * (boot snapshot, media cache, service worker caches). Runs after the
   * session is closed, in every tab where the account ends, so it must be
   * idempotent. Errors are ignored: the user is already signed out.
   */
  readonly eraseAccountData?: (userId: UserID) => Promise<void>
  /**
   * Signs out here. The app passes `signOut` from `@inline/auth/flows` with
   * the API (server revoke, then `AuthStore.logout`), without its own
   * `eraseAccountData`: this model erases when the auth store reports the
   * end. Default: `authStore.logout()`.
   */
  readonly signOut?: () => Promise<unknown>
  readonly platform: Platform
  /** A character typed outside any field with no command bound (focus the composer). */
  readonly onTypeToFocus?: (event: KeyEventLike) => void
}

export class AppModel<S extends SignInModelLike = SignInModelLike> {
  readonly phase: ReadSignal<AppPhase<S>>
  /** One registry for the app's life; a session registers its commands into it. */
  readonly registry: CommandRegistry
  /** The keyboard, resolving against `registry` and the focused region's scopes. */
  readonly keyboard: KeyboardDispatcher
  /** The session while signed in. */
  readonly session: ReadSignal<AccountSession | undefined>

  readonly #options: AppModelOptions<S>
  readonly #phase = signal<AppPhase<S>>({ kind: "booting" })
  readonly #stopAuth: () => void
  #stopSessionWatch: Dispose | undefined
  #pending: Promise<void> = Promise.resolve()
  #disposed = false

  constructor(options: AppModelOptions<S>) {
    this.#options = options
    this.phase = { get: () => this.#phase.get(), peek: () => this.#phase.peek() }
    this.session = {
      get: () => {
        const phase = this.#phase.get()
        return phase.kind === "signedIn" ? phase.session : undefined
      },
      peek: () => {
        const phase = this.#phase.peek()
        return phase.kind === "signedIn" ? phase.session : undefined
      },
    }
    this.registry = new CommandRegistry()
    this.keyboard = new KeyboardDispatcher({
      registry: this.registry,
      platform: options.platform,
      ...(options.onTypeToFocus ? { onTypeToFocus: options.onTypeToFocus } : {}),
    })
    this.#stopAuth = options.authStore.subscribe((state) => this.#sync(state))
    this.#sync(options.authStore.getState())
  }

  /** Sign out here. The account ends when the auth store reports it. */
  signOut(): Promise<unknown> {
    return this.#options.signOut ? this.#options.signOut() : this.#options.authStore.logout()
  }

  /** Resolves when an ending account has been torn down and erased. Tests and the app's shutdown use it. */
  idle(): Promise<void> {
    return this.#pending
  }

  dispose(): void {
    if (this.#disposed) return
    this.#disposed = true
    this.#stopAuth()
    this.#stopSessionWatch?.()
    const phase = this.#phase.peek()
    if (phase.kind === "signedIn") phase.session.dispose()
    if (phase.kind === "signedOut") phase.signIn.dispose?.()
  }

  #sync(state: AuthStateLike) {
    if (this.#disposed) return
    const phase = this.#phase.peek()
    if (phase.kind === "signingOut") return // re-read when the teardown finishes
    if (!state.hasHydrated && phase.kind === "booting") return
    const target = state.token && state.currentUserId ? { userId: state.currentUserId, token: state.token } : undefined

    if (phase.kind === "signedIn") {
      if (target && target.userId === phase.session.userId) return
      this.#endAccount(phase.session)
      return
    }
    if (target) {
      if (phase.kind === "signedOut") phase.signIn.dispose?.()
      this.#startSession(target.userId, target.token)
      return
    }
    if (phase.kind === "booting") this.#phase.set({ kind: "signedOut", signIn: this.#options.createSignIn() })
  }

  #startSession(userId: UserID, token: string) {
    const session = new AccountSession({
      platform: this.#options.platform,
      ...this.#options.session,
      userId,
      token,
      registry: this.registry,
    })
    this.#phase.set({ kind: "signedIn", session })
    // The core reporting a revoked session ends the account through the auth
    // store, so every tab and every path (here, elsewhere) is the same.
    this.#stopSessionWatch = scope(() => {
      effect(() => {
        if (!session.revoked.get()) return
        // Out of the effect: logging out tears this session down.
        untracked(() => {
          void Promise.resolve().then(() => {
            if (this.#phase.peek().kind === "signedIn" && this.session.peek() === session) {
              return this.#options.authStore.logout()
            }
          })
        })
      })
    })
  }

  #endAccount(session: AccountSession) {
    const userId = session.userId
    this.#stopSessionWatch?.()
    this.#stopSessionWatch = undefined
    this.#phase.set({ kind: "signingOut", userId })
    // The session's end resolves when the core has erased the account's
    // storage (or the bounded wait ran out): a new sign-in must not open
    // storage that is still being erased.
    const ended = Promise.resolve(session.end({ erase: true })).catch(() => {})
    const erase = this.#options.eraseAccountData
    const erased = erase ? erase(userId).catch(() => {}) : Promise.resolve()
    this.#pending = Promise.all([ended, erased]).then(() => {
      if (this.#disposed) return
      this.#phase.set({ kind: "signedOut", signIn: this.#options.createSignIn() })
      // A sign-in may have landed while erasing (or the end was a user switch).
      this.#sync(this.#options.authStore.getState())
    })
  }
}
