/**
 * The sign-in model behind a dynamic import, and the hold that keeps a new
 * account's setup on screen after the auth store has signed it in.
 *
 * `@inline/auth/flows` (the sign-in model, the API client, device facts and
 * the sign-out flow) is not needed to paint a signed-in shell, so it is not
 * in the initial bundle: `createAuthFlows` loads it on first use (the sign-in
 * screen, a sign-out, the settings' device name). `LazySignIn` is what the
 * app model holds while signed out: it starts the load at once and publishes
 * the real model when it arrives; the gate shows its neutral frame until both
 * the model and the sign-in screen's chunk are there.
 *
 * The hold (Mac: profile setup comes before the main window): the app model
 * starts the session as soon as the auth store logs in, which happens inside
 * the sign-in model's last request, before it moves to `setup` (a new account)
 * or `done`. So `dispose()` is deferred by a microtask: if the model then sits
 * at `setup`, it stays alive and `held` is true until it leaves `setup`
 * (Continue moves it to `done`; its back signs out), and the gate keeps the
 * sign-in screen up over the started session. `done` is never held: the shell
 * replaces the screen at once, as the sign-in README says.
 */

import type { AuthStore } from "@inline/auth/core"
import type { DeviceFacts, SignInApi, SignInModel } from "@inline/auth/flows"
import type { UserID } from "@inline/ids"
import { computed, effect, signal, type Dispose, type ReadSignal } from "@inline/reactive"

type FlowsModule = typeof import("@inline/auth/flows")

export type AuthFlows = {
  readonly module: FlowsModule
  readonly api: SignInApi
  readonly device: DeviceFacts
}

export type AuthFlowsOptions = {
  readonly authStore: AuthStore
  /** Where the device ID is kept (`localStorage`); null when storage is unavailable. */
  readonly storage: () => Storage | null
  /** The module, for tests. Default: a dynamic import of `@inline/auth/flows`. */
  readonly load?: () => Promise<FlowsModule>
}

/** Loads the flows once (again after a failure) and builds the API client and device facts. */
export const createAuthFlows = (options: AuthFlowsOptions): (() => Promise<AuthFlows>) => {
  let pending: Promise<AuthFlows> | undefined
  const load = options.load ?? (() => import("@inline/auth/flows"))
  return () => {
    pending ??= load().then(
      (module) => {
        const device = module.createDeviceFacts({
          storage: options.storage(),
          randomId: () => crypto.randomUUID(),
          environment: navigator,
          timeZone: Intl.DateTimeFormat().resolvedOptions().timeZone,
        })
        const api = module.createSignInApi({ fetch: (url, init) => fetch(url, init), device, clock: module.systemClock })
        return { module, api, device }
      },
      (error: unknown) => {
        pending = undefined
        throw error
      },
    )
    return pending
  }
}

/** The part of the sign-in model the hold reads (`SignInModel` fits). */
export type HoldableSignInModel = {
  readonly step: ReadSignal<string>
  readonly signedInUserId: ReadSignal<UserID | null>
  dispose(): void
}

/**
 * What the app model holds while signed out. `model` is undefined until the
 * flows chunk has loaded (or after it failed: `error`, `retry()`).
 */
export class LazySignIn<M extends HoldableSignInModel = SignInModel> {
  readonly model: ReadSignal<M | undefined>
  readonly error: ReadSignal<unknown>
  /** True while the app model has let go of this sign-in but a new account's setup is still on screen. */
  readonly held: ReadSignal<boolean>

  readonly #create: () => Promise<M>
  readonly #model = signal<M | undefined>(undefined)
  readonly #error = signal<unknown>(undefined)
  readonly #retired = signal(false)
  #stopHold: Dispose | undefined
  #disposed = false

  constructor(create: () => Promise<M>) {
    this.#create = create
    this.model = { get: () => this.#model.get(), peek: () => this.#model.peek() }
    this.error = { get: () => this.#error.get(), peek: () => this.#error.peek() }
    this.held = computed(() => this.#retired.get() && !this.#disposed && this.#model.get()?.step.get() === "setup")
    this.retry()
  }

  /** Load again after a failure. */
  retry(): void {
    if (this.#disposed || this.#model.peek()) return
    this.#error.set(undefined)
    this.#create().then(
      (model) => {
        if (this.#disposed || this.#retired.peek()) {
          model.dispose()
          return
        }
        this.#model.set(model)
      },
      (error: unknown) => {
        if (!this.#disposed) this.#error.set(error ?? new Error("load failed"))
      },
    )
  }

  /** The user this sign-in signed in, once it has. */
  signedInUserId(): UserID | null {
    return this.#model.peek()?.signedInUserId.peek() ?? null
  }

  /**
   * The app model is done with this sign-in (an account started, or the app
   * closed). A model that reaches `setup` in the same task stays until it
   * leaves `setup`; anything else is disposed.
   */
  dispose(): void {
    if (this.#retired.peek()) return
    this.#retired.set(true)
    queueMicrotask(() => {
      const model = this.#model.peek()
      if (!model || model.step.peek() !== "setup") {
        this.#release()
        return
      }
      let first = true
      this.#stopHold = effect(() => {
        const step = model.step.get()
        if (first) {
          first = false
          return
        }
        if (step !== "setup") queueMicrotask(() => this.#release())
      })
    })
  }

  /** Let go now, held or not (the account ended). */
  release(): void {
    if (!this.#retired.peek()) this.#retired.set(true)
    this.#release()
  }

  #release(): void {
    if (this.#disposed) return
    this.#disposed = true
    this.#stopHold?.()
    this.#stopHold = undefined
    const model = this.#model.peek()
    // `#disposed` is read by `held`; the model write notifies it.
    this.#model.set(undefined)
    model?.dispose()
  }
}
