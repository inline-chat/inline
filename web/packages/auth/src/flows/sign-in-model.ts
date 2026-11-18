/**
 * The sign-in state machine. Framework-free: state is exposed as signals and
 * changed only through the methods. See README.md for the steps and rules.
 */

import type { UserID } from "@inline/ids"
import { batch, computed, signal, type ReadSignal, type Signal } from "@inline/reactive"
import type { AuthStore } from "../core"
import type {
  ApiResult,
  DeviceFacts,
  LoginSession,
  SignInApi,
  SignInError,
  SignInUser,
} from "./api"
import type { Clock, TimerHandle } from "./clock"
import {
  buildProviderStartUrl,
  createProviderAttempt,
  parseProviderReturn,
  validateProviderReturn,
  type CryptoLike,
  type ProviderAttemptStore,
  type ProviderName,
} from "./provider"

export type SignInStep =
  | "welcome"
  | "email"
  | "phone"
  | "invite"
  | "code"
  | "provider"
  | "setup"
  | "done"

export type SignInMethod = "email" | "phone" | ProviderName

export type PendingAction =
  | "sendCode"
  | "resendCode"
  | "verifyCode"
  | "checkInvite"
  | "providerStart"
  | "providerRedeem"
  | "signOut"

/** One send per contact per minute (otpDeliveryBudget.ts:26). */
export const RESEND_COOLDOWN_MS = 60_000

/** Email challenges live ten minutes (emailLoginChallenges.ts:13). */
export const EMAIL_CODE_LIFETIME_MS = 10 * 60_000

export const INVITE_CODE_LENGTH = 8

export type ProviderSignInOptions = {
  crypto: CryptoLike
  attempts: ProviderAttemptStore
  /** The `/v1` base the start URL is built on. */
  apiBaseUrl: string
  /** Where the server should send the tab back to (an allow-listed origin). */
  returnUrl: string
  device: () => DeviceFacts
}

export type SignInModelOptions = {
  api: SignInApi
  authStore: AuthStore
  clock: Clock
  /**
   * Runs when the user goes back after signing in. Defaults to
   * `authStore.logout()`; the app passes the full `signOut` from `./sign-out`.
   */
  signOut?: () => Promise<unknown>
  provider?: ProviderSignInOptions
  /**
   * How long a code is known to live, per method. A wrong-code answer after
   * that is reported as `expiredCode`; the server does not tell the two apart.
   * Phone defaults to null: the SMS provider's lifetime is not in our code.
   */
  codeLifetimeMs?: { email: number | null; phone: number | null }
  resendCooldownMs?: number
}

export interface SignInModel {
  readonly step: ReadSignal<SignInStep>
  readonly method: ReadSignal<SignInMethod | null>
  readonly pending: ReadSignal<PendingAction | null>
  /** The error for the current step; cleared when the step changes. */
  readonly error: ReadSignal<SignInError | null>
  /** The email or formatted phone number the code went to. */
  readonly contact: ReadSignal<string | null>
  /** From the server's send answer: true for sign-in, false for a new account. */
  readonly existingUser: ReadSignal<boolean | null>
  /** The accepted access invite code, to prefill the invite step on return. */
  readonly inviteCode: ReadSignal<string | null>
  /** Whole seconds until a new code may be sent; 0 when it may. */
  readonly resendSeconds: ReadSignal<number>
  readonly canResend: ReadSignal<boolean>
  readonly canGoBack: ReadSignal<boolean>
  readonly signedInUserId: ReadSignal<UserID | null>
  readonly user: ReadSignal<SignInUser | null>

  chooseEmail(): void
  choosePhone(): void
  submitEmail(email: string): Promise<void>
  submitPhone(phoneNumber: string): Promise<void>
  submitCode(code: string): Promise<void>
  resendCode(): Promise<void>
  submitInvite(inviteCode: string): Promise<void>
  /** Returns the URL to navigate the tab to, or null when it cannot start. */
  startProvider(provider: ProviderName): Promise<string | null>
  /** Call once at boot with the current URL; does nothing without hand-off parameters. */
  completeProvider(returnUrl: string): Promise<void>
  finishSetup(): void
  back(): Promise<void>
  clearError(): void
  dispose(): void
}

export const createSignInModel = (options: SignInModelOptions): SignInModel =>
  new SignInModelImpl(options)

const normalizeCode = (value: string) => value.replace(/\D/g, "")

const normalizeInvite = (value: string) =>
  value.toUpperCase().replace(/[^A-Z0-9]/g, "").slice(0, INVITE_CODE_LENGTH)

class SignInModelImpl implements SignInModel {
  private readonly pathSignal = signal<readonly SignInStep[]>(["welcome"])
  private readonly methodSignal = signal<SignInMethod | null>(null)
  private readonly pendingSignal = signal<PendingAction | null>(null)
  private readonly errorSignal = signal<SignInError | null>(null)
  private readonly contactSignal = signal<string | null>(null)
  private readonly existingUserSignal = signal<boolean | null>(null)
  private readonly inviteCodeSignal = signal<string | null>(null)
  private readonly resendAtSignal = signal(0)
  private readonly nowSignal: Signal<number>
  private readonly userIdSignal = signal<UserID | null>(null)
  private readonly userSignal = signal<SignInUser | null>(null)

  readonly step: ReadSignal<SignInStep>
  readonly resendSeconds: ReadSignal<number>
  readonly canResend: ReadSignal<boolean>
  readonly canGoBack: ReadSignal<boolean>

  private readonly api: SignInApi
  private readonly authStore: AuthStore
  private readonly clock: Clock
  private readonly signOutFn: () => Promise<unknown>
  private readonly codeLifetimeMs: { email: number | null; phone: number | null }
  private readonly resendCooldownMs: number

  /** Bumped on every step change; a response from an older generation is stale. */
  private generation = 0
  private disposed = false
  private tick: TimerHandle | null = null

  // Values that travel between steps but are not shown.
  private email: string | null = null
  private challengeToken: string | null = null
  private phoneE164: string | null = null
  private codeSentAt = 0
  /** A code the server took but answered with "invite required". */
  private codeAwaitingInvite: string | null = null

  constructor(private readonly options: SignInModelOptions) {
    this.api = options.api
    this.authStore = options.authStore
    this.clock = options.clock
    this.signOutFn = options.signOut ?? (() => options.authStore.logout())
    this.codeLifetimeMs = options.codeLifetimeMs ?? { email: EMAIL_CODE_LIFETIME_MS, phone: null }
    this.resendCooldownMs = options.resendCooldownMs ?? RESEND_COOLDOWN_MS
    this.nowSignal = signal(this.clock.now())

    this.step = computed(() => {
      const path = this.pathSignal.get()
      return path[path.length - 1] ?? "welcome"
    })
    this.resendSeconds = computed(() => {
      if (this.step.get() !== "code") return 0
      const remaining = this.resendAtSignal.get() - this.nowSignal.get()
      return remaining > 0 ? Math.ceil(remaining / 1000) : 0
    })
    this.canResend = computed(
      () =>
        this.step.get() === "code" &&
        this.pendingSignal.get() === null &&
        this.resendSeconds.get() === 0,
    )
    this.canGoBack = computed(
      () => this.pathSignal.get().length > 1 && this.pendingSignal.get() !== "signOut",
    )
  }

  get method() {
    return this.methodSignal as ReadSignal<SignInMethod | null>
  }
  get pending() {
    return this.pendingSignal as ReadSignal<PendingAction | null>
  }
  get error() {
    return this.errorSignal as ReadSignal<SignInError | null>
  }
  get contact() {
    return this.contactSignal as ReadSignal<string | null>
  }
  get existingUser() {
    return this.existingUserSignal as ReadSignal<boolean | null>
  }
  get inviteCode() {
    return this.inviteCodeSignal as ReadSignal<string | null>
  }
  get signedInUserId() {
    return this.userIdSignal as ReadSignal<UserID | null>
  }
  get user() {
    return this.userSignal as ReadSignal<SignInUser | null>
  }

  // -------------------------------------------------------------------------
  // Actions

  chooseEmail() {
    this.choose("email")
  }

  choosePhone() {
    this.choose("phone")
  }

  async submitEmail(raw: string) {
    if (this.step.peek() !== "email" || this.pendingSignal.peek() !== null) return
    const email = raw.trim()
    if (email.length === 0) return this.localError({ kind: "invalidEmail" })

    const generation = this.begin("sendCode")
    if (generation === null) return
    const result = await this.api.sendEmailCode(email)
    if (!this.isCurrent(generation)) return
    if (!result.ok) return this.fail(result.error)

    this.email = email
    this.phoneE164 = null
    this.challengeToken = result.value.challengeToken
    this.codeSentAfterSend(email, result.value.existingUser, result.value.needsInviteCode)
  }

  async submitPhone(raw: string) {
    if (this.step.peek() !== "phone" || this.pendingSignal.peek() !== null) return
    const phoneNumber = raw.trim()
    if (phoneNumber.length === 0) return this.localError({ kind: "invalidPhone" })

    const generation = this.begin("sendCode")
    if (generation === null) return
    const result = await this.api.sendSmsCode(phoneNumber)
    if (!this.isCurrent(generation)) return
    if (!result.ok) return this.fail(result.error)

    this.email = null
    this.challengeToken = null
    this.phoneE164 = result.value.phoneNumber
    this.codeSentAfterSend(
      result.value.formattedPhoneNumber,
      result.value.existingUser,
      result.value.needsInviteCode,
    )
  }

  async submitCode(raw: string) {
    if (this.step.peek() !== "code" || this.pendingSignal.peek() !== null) return
    const code = normalizeCode(raw)
    if (code.length === 0) return this.localError({ kind: "invalidCode" })

    const generation = this.begin("verifyCode")
    if (generation === null) return
    const inviteCode = this.inviteCodeSignal.peek()
    const result: ApiResult<LoginSession> =
      this.methodSignal.peek() === "email"
        ? await this.api.verifyEmailCode({
            email: this.email ?? "",
            code,
            challengeToken: this.challengeToken,
            inviteCode,
          })
        : await this.api.verifySmsCode({
            phoneNumber: this.phoneE164 ?? "",
            code,
            inviteCode,
          })

    if (!this.isCurrent(generation)) {
      if (result.ok) this.discardSession(result.value.token)
      return
    }
    if (result.ok) return this.completeLogin(result.value)

    if (result.error.kind === "inviteRequired") {
      // The server's routing signal, not a failure: ask for the invite, then
      // send this code again with it. Email codes are not spent by this
      // answer (emailLoginChallenges.ts verifyEmailLoginChallenge).
      this.codeAwaitingInvite = code
      const path = this.pathSignal.peek()
      this.go([...path.slice(0, -1), "invite"])
      return
    }
    this.fail(this.refineCodeError(result.error))
  }

  async resendCode() {
    if (!this.canResend.peek()) return
    const generation = this.begin("resendCode")
    if (generation === null) return
    const isEmail = this.methodSignal.peek() === "email"
    const result = isEmail
      ? await this.api.sendEmailCode(this.email ?? "")
      : await this.api.sendSmsCode(this.phoneE164 ?? "")
    if (!this.isCurrent(generation)) return

    const now = this.clock.now()
    if (!result.ok) {
      if (result.error.kind === "rateLimited") {
        const waitMs = (result.error.retryAfterSeconds ?? this.resendCooldownMs / 1000) * 1000
        this.setResendAt(now + waitMs)
      }
      return this.fail(result.error)
    }
    if ("challengeToken" in result.value) this.challengeToken = result.value.challengeToken
    if ("phoneNumber" in result.value) this.phoneE164 = result.value.phoneNumber
    this.codeSentAt = now
    batch(() => {
      this.setResendAt(now + this.resendCooldownMs)
      this.pendingSignal.set(null)
    })
  }

  async submitInvite(raw: string) {
    if (this.step.peek() !== "invite" || this.pendingSignal.peek() !== null) return
    const inviteCode = normalizeInvite(raw)
    if (inviteCode.length !== INVITE_CODE_LENGTH) {
      return this.localError({ kind: "invalidInvite", reason: "format" })
    }

    const generation = this.begin("checkInvite")
    if (generation === null) return
    const result = await this.api.checkInviteCode(inviteCode)
    if (!this.isCurrent(generation)) return
    if (!result.ok) return this.fail(result.error)
    if (!result.value.valid) return this.fail({ kind: "invalidInvite", reason: "notFound" })

    const resumeCode = this.codeAwaitingInvite
    this.codeAwaitingInvite = null
    batch(() => {
      this.inviteCodeSignal.set(inviteCode)
      this.go([...this.pathSignal.peek(), "code"])
    })
    if (resumeCode !== null) await this.submitCode(resumeCode)
  }

  async startProvider(provider: ProviderName): Promise<string | null> {
    const step = this.step.peek()
    if ((step !== "welcome" && step !== "provider") || this.pendingSignal.peek() !== null) return null
    const config = this.options.provider
    if (!config) {
      this.localError({ kind: "providerFailed" })
      return null
    }

    const generation = this.begin("providerStart")
    if (generation === null) return null
    let attempt
    try {
      attempt = await createProviderAttempt(config.crypto, provider, this.clock.now())
    } catch {
      if (this.isCurrent(generation)) this.fail({ kind: "providerFailed" })
      return null
    }
    if (!this.isCurrent(generation)) return null
    if (!config.attempts.save(attempt)) {
      // Without a stored verifier the return can never be redeemed.
      this.fail({ kind: "providerFailed" })
      return null
    }
    const url = buildProviderStartUrl({
      apiBaseUrl: config.apiBaseUrl,
      provider,
      codeChallenge: attempt.codeChallenge,
      device: config.device(),
      returnUrl: config.returnUrl,
    })
    batch(() => {
      this.methodSignal.set(provider)
      this.go(["welcome", "provider"])
    })
    return url
  }

  async completeProvider(returnUrl: string) {
    if (this.pendingSignal.peek() !== null || this.disposed) return
    const returned = parseProviderReturn(returnUrl)
    const attempts = this.options.provider?.attempts
    if (!returned || !attempts) return

    // Single use: whatever came back, this attempt is finished.
    const pendingAttempt = attempts.load()
    attempts.clear()
    const checked = validateProviderReturn(returned, pendingAttempt, this.clock.now())
    batch(() => {
      this.methodSignal.set(checked.provider)
      this.go(["welcome", "provider"])
      if (!checked.ok) this.errorSignal.set(checked.error)
    })
    if (!checked.ok) return

    const generation = this.begin("providerRedeem")
    if (generation === null) return
    const result = await this.api.redeemProviderTicket({
      ticket: checked.ticket,
      codeVerifier: checked.codeVerifier,
    })
    if (!this.isCurrent(generation)) {
      if (result.ok) this.discardSession(result.value.token)
      return
    }
    if (!result.ok) return this.fail(result.error)
    await this.completeLogin(result.value)
  }

  finishSetup() {
    if (this.step.peek() !== "setup" || this.pendingSignal.peek() !== null) return
    this.go([...this.pathSignal.peek(), "done"])
  }

  async back() {
    if (this.disposed) return
    if (this.userIdSignal.peek() !== null) {
      // Back after authentication signs out, as the Mac onboarding does.
      if (this.pendingSignal.peek() === "signOut") return
      batch(() => {
        this.pendingSignal.set("signOut")
        this.errorSignal.set(null)
      })
      const generation = this.generation
      try {
        await this.signOutFn()
      } catch {
        // The sign-out function reports its own outcome; the model restarts regardless.
      }
      if (this.disposed || generation !== this.generation) return
      this.resetToWelcome()
      return
    }

    const path = this.pathSignal.peek()
    if (path.length <= 1) return
    const leaving = path[path.length - 1]
    if (leaving === "provider") this.options.provider?.attempts.clear()
    const next = path.slice(0, -1)
    const landing = next[next.length - 1]
    if (landing === "email" || landing === "phone" || landing === "welcome") {
      this.codeAwaitingInvite = null
    }
    if (landing === "welcome") this.methodSignal.set(null)
    this.go(next)
  }

  clearError() {
    this.errorSignal.set(null)
  }

  dispose() {
    this.disposed = true
    this.generation += 1
    this.cancelTick()
  }

  // -------------------------------------------------------------------------
  // Internals

  private choose(method: "email" | "phone") {
    if (this.step.peek() !== "welcome" || this.pendingSignal.peek() !== null) return
    batch(() => {
      this.methodSignal.set(method)
      this.go(["welcome", method])
    })
  }

  private codeSentAfterSend(contact: string, existingUser: boolean, needsInviteCode: boolean) {
    const now = this.clock.now()
    this.codeSentAt = now
    this.codeAwaitingInvite = null
    batch(() => {
      this.contactSignal.set(contact)
      this.existingUserSignal.set(existingUser)
      this.inviteCodeSignal.set(null)
      this.setResendAt(now + this.resendCooldownMs)
      this.go([...this.pathSignal.peek(), needsInviteCode ? "invite" : "code"])
    })
  }

  private async completeLogin(session: LoginSession) {
    const saved = this.authStore.login({ token: session.token, userId: session.userId })
    batch(() => {
      this.userIdSignal.set(session.userId)
      this.userSignal.set(session.user)
      this.go([...this.pathSignal.peek(), session.user.pendingSetup ? "setup" : "done"])
    })
    await saved
  }

  private refineCodeError(error: SignInError): SignInError {
    if (error.kind !== "invalidCode") return error
    const method = this.methodSignal.peek()
    const lifetime =
      method === "email" ? this.codeLifetimeMs.email : method === "phone" ? this.codeLifetimeMs.phone : null
    if (lifetime != null && this.clock.now() - this.codeSentAt >= lifetime) {
      return { kind: "expiredCode" }
    }
    return error
  }

  /** A session that arrived for a step the user already left: revoke it. */
  private discardSession(token: string) {
    void this.api.logout(token).catch(() => undefined)
  }

  /** Starts a request; returns its generation, or null when one is running. */
  private begin(action: PendingAction): number | null {
    if (this.disposed || this.pendingSignal.peek() !== null) return null
    batch(() => {
      this.pendingSignal.set(action)
      this.errorSignal.set(null)
    })
    return this.generation
  }

  private isCurrent(generation: number) {
    return !this.disposed && generation === this.generation
  }

  private fail(error: SignInError) {
    batch(() => {
      this.errorSignal.set(error)
      this.pendingSignal.set(null)
    })
  }

  private localError(error: SignInError) {
    if (this.pendingSignal.peek() !== null) return
    this.errorSignal.set(error)
  }

  /** Every step change goes through here: it abandons any running request. */
  private go(path: readonly SignInStep[]) {
    this.generation += 1
    batch(() => {
      this.pathSignal.set(path)
      this.pendingSignal.set(null)
      this.errorSignal.set(null)
    })
  }

  private resetToWelcome() {
    this.email = null
    this.challengeToken = null
    this.phoneE164 = null
    this.codeAwaitingInvite = null
    this.cancelTick()
    batch(() => {
      this.methodSignal.set(null)
      this.contactSignal.set(null)
      this.existingUserSignal.set(null)
      this.inviteCodeSignal.set(null)
      this.userIdSignal.set(null)
      this.userSignal.set(null)
      this.resendAtSignal.set(0)
      this.go(["welcome"])
    })
  }

  private setResendAt(at: number) {
    batch(() => {
      this.resendAtSignal.set(at)
      this.nowSignal.set(this.clock.now())
    })
    this.scheduleTick()
  }

  private scheduleTick() {
    this.cancelTick()
    if (this.disposed) return
    const remaining = this.resendAtSignal.peek() - this.clock.now()
    if (remaining <= 0) return
    const delay = remaining % 1000 || 1000
    this.tick = this.clock.setTimeout(() => {
      this.tick = null
      this.nowSignal.set(this.clock.now())
      this.scheduleTick()
    }, delay)
  }

  private cancelTick() {
    if (this.tick !== null) {
      this.clock.clearTimeout(this.tick)
      this.tick = null
    }
  }
}
