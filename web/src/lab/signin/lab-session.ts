/**
 * The sign-in lab's wiring: a real `SignInModel` over the real sign-in API
 * client, with the lab's scripted server as `fetch`, an in-memory auth store
 * and in-memory provider attempt storage. Framework-free; the lab view only
 * renders it.
 *
 * `globalThis.__signinLab` reads the current state as plain data (a getter,
 * so every read is fresh). `globalThis.__signinLabControl` drives the lab
 * without the control strip.
 */

import { AuthStore } from "@inline/auth/core"
import {
  createSignInApi,
  createSignInModel,
  ProviderAttemptStore,
  type DeviceFacts,
  type KeyValueStorage,
  type SignInModel,
} from "@inline/auth/flows"
import { signal } from "@inline/reactive"
import { LAB_ANSWERS, LAB_API_BASE, LabClock, LabServer, type LabAnswer } from "./lab-server"

export type LabTheme = "system" | "light" | "dark"
export type LabDir = "ltr" | "rtl"
export type LabWidth = "auto" | "320"

const DEVICE: DeviceFacts = { deviceId: "lab-device", deviceName: "Sign-in lab", timeZone: "Europe/London" }

class MemoryStorage implements KeyValueStorage {
  private readonly values = new Map<string, string>()
  getItem(key: string) {
    return this.values.get(key) ?? null
  }
  setItem(key: string, value: string) {
    this.values.set(key, value)
  }
  removeItem(key: string) {
    this.values.delete(key)
  }
}

export class SignInLab {
  readonly clock = new LabClock()
  readonly server = new LabServer(this.clock)

  // Lab settings, as signals so the strip and the global snapshot agree.
  readonly theme = signal<LabTheme>("system")
  readonly dir = signal<LabDir>("ltr")
  readonly width = signal<LabWidth>("auto")
  readonly providersEnabled = signal(false)
  readonly autoSubmitLength = signal<number | null>(6)
  /** Bumped by reset; the view creates a new model for each value. */
  readonly generation = signal(0)
  /** The last URL the screen asked to navigate to (provider start). */
  readonly lastNavigation = signal<string | null>(null)

  private current: { model: SignInModel; authStore: AuthStore; attempts: ProviderAttemptStore } | null = null

  /** Creates the model for the current generation. The view owns and disposes it. */
  createModel(): SignInModel {
    const authStore = new AuthStore()
    const attempts = new ProviderAttemptStore(new MemoryStorage())
    const api = createSignInApi({
      fetch: this.server.fetch,
      apiBaseUrl: LAB_API_BASE,
      device: DEVICE,
      clock: this.clock,
    })
    const model = createSignInModel({
      api,
      authStore,
      clock: this.clock,
      provider: {
        crypto: globalThis.crypto,
        attempts,
        apiBaseUrl: LAB_API_BASE,
        returnUrl: `${location.origin}/lab-signin.html`,
        device: () => DEVICE,
      },
    })
    this.current = { model, authStore, attempts }
    return model
  }

  reset() {
    this.clock.offsetMs = 0
    this.server.next.set("success")
    this.server.requests.set([])
    this.lastNavigation.set(null)
    this.generation.set(this.generation.peek() + 1)
  }

  setNext(answer: LabAnswer) {
    if (LAB_ANSWERS.includes(answer)) this.server.next.set(answer)
  }

  navigate = (url: string) => {
    // Never leave the lab: record where the screen would have gone, without
    // the query (it carries the PKCE challenge and device fields).
    this.lastNavigation.set(url.split("?")[0] ?? url)
  }

  /**
   * Comes back from the provider as the server's hand-off would: with a
   * ticket, a cancellation, or a challenge that does not match this tab's.
   */
  async returnFromProvider(kind: "ticket" | "cancelled" | "mismatch") {
    const current = this.current
    if (!current) return
    const challenge = current.attempts.load()?.codeChallenge ?? "no-attempt"
    const params = new URLSearchParams()
    if (kind === "ticket") params.set("ticket", "lab-ticket")
    if (kind === "cancelled") params.set("error", "cancelled")
    params.set("code_challenge", kind === "mismatch" ? "another-tab" : challenge)
    await current.model.completeProvider(`https://lab.invalid/return?${params.toString()}`)
  }

  /** The current state as plain data. Contains no codes or tokens. */
  snapshot() {
    const current = this.current
    const model = current?.model
    const auth = current?.authStore.getState()
    return {
      step: model?.step.peek() ?? null,
      method: model?.method.peek() ?? null,
      pending: model?.pending.peek() ?? null,
      error: model?.error.peek() ?? null,
      contact: model?.contact.peek() ?? null,
      existingUser: model?.existingUser.peek() ?? null,
      inviteCode: model?.inviteCode.peek() ?? null,
      resendSeconds: model?.resendSeconds.peek() ?? 0,
      canResend: model?.canResend.peek() ?? false,
      canGoBack: model?.canGoBack.peek() ?? false,
      signedInUserId: model?.signedInUserId.peek() ?? null,
      user: model?.user.peek() ?? null,
      auth: auth ? { status: auth.status, userId: auth.currentUserId } : null,
      server: {
        next: this.server.next.peek(),
        newAccount: this.server.newAccount.peek(),
        requests: this.server.requests.peek(),
        clockOffsetMs: this.clock.offsetMs,
      },
      lab: {
        theme: this.theme.peek(),
        dir: this.dir.peek(),
        width: this.width.peek(),
        providersEnabled: this.providersEnabled.peek(),
        autoSubmitLength: this.autoSubmitLength.peek(),
        lastNavigation: this.lastNavigation.peek(),
      },
    }
  }
}

export const applyTheme = (theme: LabTheme) => {
  document.documentElement.style.colorScheme = theme === "system" ? "light dark" : theme
}

export const applyDir = (dir: LabDir) => {
  document.documentElement.dir = dir
}

/** Exposes the lab on `globalThis` for the coordinator's browser checks. */
export const exposeLab = (lab: SignInLab) => {
  Object.defineProperty(globalThis, "__signinLab", {
    configurable: true,
    get: () => lab.snapshot(),
  })
  Object.defineProperty(globalThis, "__signinLabControl", {
    configurable: true,
    value: {
      setNext: (answer: LabAnswer) => lab.setNext(answer),
      setNewAccount: (on: boolean) => lab.server.newAccount.set(on),
      setProvidersEnabled: (on: boolean) => lab.providersEnabled.set(on),
      setAutoSubmitLength: (length: number | null) => lab.autoSubmitLength.set(length),
      setTheme: (theme: LabTheme) => {
        applyTheme(theme)
        lab.theme.set(theme)
      },
      setDir: (dir: LabDir) => {
        applyDir(dir)
        lab.dir.set(dir)
      },
      setWidth: (width: LabWidth) => lab.width.set(width),
      returnFromProvider: (kind: "ticket" | "cancelled" | "mismatch") => lab.returnFromProvider(kind),
      reset: () => lab.reset(),
    },
  })
}
