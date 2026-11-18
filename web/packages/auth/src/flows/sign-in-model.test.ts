import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"
import { AuthStore } from "../core"
import { MemoryAuthSessionPersistence } from "../persistence"
import { createSignInApi, type DeviceFacts } from "./api"
import { ProviderAttemptStore, codeChallengeFor } from "./provider"
import { createSignInModel, type SignInModelOptions } from "./sign-in-model"
import { signOut } from "./sign-out"
import {
  API_BASE,
  MemoryStorage,
  SECRET_TOKEN,
  ScriptedFetch,
  VirtualClock,
  apiError,
  flushMicrotasks,
  hold,
  loginResult,
  networkFailure,
  ok,
} from "./test-support"

const device: DeviceFacts = {
  deviceId: "0f4c2b1e-7a7d-4f0e-9c55-3f2d0c1b9a01",
  deviceName: "Chrome on macOS",
  clientVersion: "1.2.3",
  timeZone: "Europe/Berlin",
}

const deviceBody = {
  deviceId: device.deviceId,
  clientType: "web",
  clientVersion: "1.2.3",
  deviceName: "Chrome on macOS",
}

const RETURN_URL = "https://app.test/auth/provider"

const setup = (overrides: Partial<SignInModelOptions> = {}) => {
  const clock = new VirtualClock()
  const server = new ScriptedFetch()
  const persistence = new MemoryAuthSessionPersistence()
  const authStore = new AuthStore({ storage: persistence })
  const api = createSignInApi({ fetch: server.fetch, apiBaseUrl: API_BASE, device, clock })
  const sessionStorage = new MemoryStorage()
  const attempts = new ProviderAttemptStore(sessionStorage)
  const model = createSignInModel({
    api,
    authStore,
    clock,
    signOut: () => signOut({ authStore, api, clock }),
    provider: {
      crypto: globalThis.crypto,
      attempts,
      apiBaseUrl: API_BASE,
      returnUrl: RETURN_URL,
      device: () => device,
    },
    ...overrides,
  })
  return { clock, server, persistence, authStore, api, model, attempts, sessionStorage }
}

const consoleSpies: Array<ReturnType<typeof vi.spyOn>> = []

beforeEach(() => {
  for (const method of ["log", "info", "warn", "error", "debug", "trace"] as const) {
    consoleSpies.push(vi.spyOn(console, method))
  }
})

afterEach(() => {
  // No flow code logs anything, so no code, token or ticket can leak there.
  for (const spy of consoleSpies) expect(spy).not.toHaveBeenCalled()
  consoleSpies.splice(0).forEach((spy) => spy.mockRestore())
})

const toEmailCode = async (ctx: ReturnType<typeof setup>, sendResult: object = {}) => {
  ctx.server.on(
    "/sendEmailCode",
    ok({ existingUser: true, needsInviteCode: false, challengeToken: "chal-1", ...sendResult }),
  )
  ctx.model.chooseEmail()
  await ctx.model.submitEmail("ada@example.com")
}

describe("email sign-in", () => {
  it("sends the code and verifies it with the exact request shapes", async () => {
    const ctx = setup()
    const { model, server, authStore, persistence } = ctx
    expect(model.step.get()).toBe("welcome")
    expect(model.canGoBack.get()).toBe(false)

    model.chooseEmail()
    expect(model.step.get()).toBe("email")
    expect(model.method.get()).toBe("email")

    server.on("/sendEmailCode", ok({ existingUser: true, needsInviteCode: false, challengeToken: "chal-1" }))
    await model.submitEmail("  ada@example.com ")
    expect(server.requests).toEqual([
      {
        path: "/sendEmailCode",
        method: "POST",
        headers: { accept: "application/json", "content-type": "application/json" },
        body: { email: "ada@example.com", ...deviceBody },
        credentials: "omit",
      },
    ])
    expect(model.step.get()).toBe("code")
    expect(model.contact.get()).toBe("ada@example.com")
    expect(model.existingUser.get()).toBe(true)
    expect(model.pending.get()).toBeNull()

    server.on("/verifyEmailCode", ok(loginResult()))
    await model.submitCode("123 456")
    expect(server.to("/verifyEmailCode")[0]?.body).toEqual({
      email: "ada@example.com",
      code: "123456",
      challengeToken: "chal-1",
      ...deviceBody,
      timezone: "Europe/Berlin",
    })
    expect(model.step.get()).toBe("done")
    expect(model.signedInUserId.get()).toBe("42")
    expect(model.user.get()?.firstName).toBe("Ada")
    expect(authStore.getState()).toMatchObject({
      status: "authenticated",
      storageStatus: "ready",
      token: SECRET_TOKEN,
      currentUserId: "42",
    })
    expect(await persistence.load()).toEqual({
      status: "ready",
      session: { token: SECRET_TOKEN, userId: "42" },
    })
  })

  it("keeps the step on a wrong code, then accepts the right one", async () => {
    const ctx = setup()
    await toEmailCode(ctx)
    ctx.server.on("/verifyEmailCode", apiError(400, "EMAIL_CODE_INVALID"), ok(loginResult()))

    await ctx.model.submitCode("111111")
    expect(ctx.model.step.get()).toBe("code")
    expect(ctx.model.error.get()).toEqual({ kind: "invalidCode" })
    expect(ctx.model.pending.get()).toBeNull()
    expect(ctx.authStore.isLoggedIn()).toBe(false)

    await ctx.model.submitCode("123456")
    expect(ctx.model.error.get()).toBeNull()
    expect(ctx.model.step.get()).toBe("done")
  })

  it("reports an expired code once the email code lifetime has passed", async () => {
    const ctx = setup()
    await toEmailCode(ctx)
    ctx.server.on(
      "/verifyEmailCode",
      apiError(400, "EMAIL_CODE_INVALID"),
      apiError(400, "EMAIL_CODE_INVALID"),
    )

    await ctx.clock.advance(9 * 60_000)
    await ctx.model.submitCode("123456")
    expect(ctx.model.error.get()).toEqual({ kind: "invalidCode" })

    await ctx.clock.advance(60_000)
    await ctx.model.submitCode("123456")
    expect(ctx.model.error.get()).toEqual({ kind: "expiredCode" })
    expect(ctx.model.step.get()).toBe("code")
  })

  it("stays on the email step when rate limited", async () => {
    const ctx = setup()
    ctx.model.chooseEmail()
    ctx.server.on(
      "/sendEmailCode",
      apiError(420, "FLOOD", { "retry-after": "30" }),
      { status: 429, body: { error: "rate_limited" } },
    )
    await ctx.model.submitEmail("ada@example.com")
    expect(ctx.model.step.get()).toBe("email")
    expect(ctx.model.error.get()).toEqual({ kind: "rateLimited", retryAfterSeconds: 30 })

    await ctx.model.submitEmail("ada@example.com")
    expect(ctx.model.error.get()).toEqual({ kind: "rateLimited", retryAfterSeconds: null })
  })

  it("rejects an empty email locally without a request", async () => {
    const ctx = setup()
    ctx.model.chooseEmail()
    await ctx.model.submitEmail("   ")
    expect(ctx.model.error.get()).toEqual({ kind: "invalidEmail" })
    expect(ctx.server.requests).toHaveLength(0)
  })
})

describe("phone sign-in", () => {
  it("verifies with the number the server normalized", async () => {
    const { model, server, authStore } = setup()
    model.choosePhone()
    expect(model.step.get()).toBe("phone")

    server.on(
      "/sendSmsCode",
      ok({
        existingUser: false,
        needsInviteCode: false,
        phoneNumber: "+14155550100",
        formattedPhoneNumber: "+1 415 555 0100",
      }),
    )
    await model.submitPhone("+1 (415) 555-0100")
    expect(server.to("/sendSmsCode")[0]?.body).toEqual({ phoneNumber: "+1 (415) 555-0100", ...deviceBody })
    expect(model.step.get()).toBe("code")
    expect(model.contact.get()).toBe("+1 415 555 0100")
    expect(model.existingUser.get()).toBe(false)

    server.on("/verifySmsCode", ok(loginResult({ email: null, phoneNumber: "+14155550100" })))
    await model.submitCode("654321")
    expect(server.to("/verifySmsCode")[0]?.body).toEqual({
      phoneNumber: "+14155550100",
      code: "654321",
      ...deviceBody,
      timezone: "Europe/Berlin",
    })
    expect(model.step.get()).toBe("done")
    expect(authStore.getState().currentUserId).toBe("42")
  })

  it("does not infer expiry for SMS codes", async () => {
    const { model, server, clock } = setup()
    model.choosePhone()
    server.on(
      "/sendSmsCode",
      ok({ existingUser: true, needsInviteCode: false, phoneNumber: "+14155550100", formattedPhoneNumber: "x" }),
    )
    await model.submitPhone("+14155550100")
    await clock.advance(60 * 60_000)
    server.on("/verifySmsCode", apiError(400, "SMS_CODE_INVALID"))
    await model.submitCode("000000")
    expect(model.error.get()).toEqual({ kind: "invalidCode" })
  })
})

describe("access invite code", () => {
  it("asks for the invite before the code when the send answer requires it", async () => {
    const ctx = setup()
    await toEmailCode(ctx, { existingUser: false, needsInviteCode: true })
    expect(ctx.model.step.get()).toBe("invite")

    ctx.server.on("/checkInviteCode", apiError(400, "INVITE_CODE_NOT_FOUND"), ok({ valid: true }))
    await ctx.model.submitInvite("a7k2-pq9x")
    expect(ctx.server.to("/checkInviteCode")[0]?.body).toEqual({ inviteCode: "A7K2PQ9X" })
    expect(ctx.model.step.get()).toBe("invite")
    expect(ctx.model.error.get()).toEqual({ kind: "invalidInvite", reason: "notFound" })

    await ctx.model.submitInvite("A7K2PQ9X")
    expect(ctx.model.step.get()).toBe("code")
    expect(ctx.model.inviteCode.get()).toBe("A7K2PQ9X")

    ctx.server.on("/verifyEmailCode", ok(loginResult({ pendingSetup: true })))
    await ctx.model.submitCode("123456")
    expect(ctx.server.to("/verifyEmailCode")[0]?.body).toMatchObject({ inviteCode: "A7K2PQ9X" })
    expect(ctx.model.step.get()).toBe("setup")
  })

  it("rejects a malformed invite locally", async () => {
    const ctx = setup()
    await toEmailCode(ctx, { needsInviteCode: true })
    await ctx.model.submitInvite("abc")
    expect(ctx.model.error.get()).toEqual({ kind: "invalidInvite", reason: "format" })
    expect(ctx.server.to("/checkInviteCode")).toHaveLength(0)
  })

  it("routes to the invite when verify says one is required, then resubmits the code", async () => {
    const ctx = setup()
    await toEmailCode(ctx, { needsInviteCode: false })
    ctx.server.on(
      "/verifyEmailCode",
      apiError(400, "INVITE_CODE_REQUIRED"),
      ok(loginResult()),
    )

    await ctx.model.submitCode("123456")
    expect(ctx.model.step.get()).toBe("invite")
    expect(ctx.model.error.get()).toBeNull()

    ctx.server.on("/checkInviteCode", ok({ valid: true }))
    await ctx.model.submitInvite("A7K2PQ9X")
    const verifies = ctx.server.to("/verifyEmailCode")
    expect(verifies).toHaveLength(2)
    expect(verifies[1]?.body).toMatchObject({ code: "123456", inviteCode: "A7K2PQ9X", challengeToken: "chal-1" })
    expect(ctx.model.step.get()).toBe("done")

    // The invite sits where it would have been asked: back signs out from done,
    // but the path before sign-in was welcome, email, invite, code.
  })
})

describe("pending setup", () => {
  it("shows setup for an account with pending setup and finishes to done", async () => {
    const ctx = setup()
    await toEmailCode(ctx)
    ctx.server.on("/verifyEmailCode", ok(loginResult({ pendingSetup: true })))
    await ctx.model.submitCode("123456")
    expect(ctx.model.step.get()).toBe("setup")
    expect(ctx.model.signedInUserId.get()).toBe("42")
    expect(ctx.authStore.isLoggedIn()).toBe(true)

    ctx.model.finishSetup()
    expect(ctx.model.step.get()).toBe("done")
  })
})

describe("resend", () => {
  it("counts down on the clock and resends to the same contact", async () => {
    const ctx = setup()
    await toEmailCode(ctx)
    const { model, clock, server } = ctx
    expect(model.resendSeconds.get()).toBe(60)
    expect(model.canResend.get()).toBe(false)

    await model.resendCode()
    expect(server.to("/sendEmailCode")).toHaveLength(1)

    await clock.advance(30_000)
    expect(model.resendSeconds.get()).toBe(30)
    await clock.advance(29_500)
    expect(model.resendSeconds.get()).toBe(1)
    await clock.advance(500)
    expect(model.resendSeconds.get()).toBe(0)
    expect(model.canResend.get()).toBe(true)
    expect(clock.pendingTimers).toBe(0)

    server.on("/sendEmailCode", ok({ existingUser: true, needsInviteCode: false, challengeToken: "chal-2" }))
    await model.resendCode()
    expect(server.to("/sendEmailCode")[1]?.body).toEqual({ email: "ada@example.com", ...deviceBody })
    expect(model.resendSeconds.get()).toBe(60)
    expect(model.step.get()).toBe("code")

    server.on("/verifyEmailCode", ok(loginResult()))
    await model.submitCode("222222")
    expect(server.to("/verifyEmailCode")[0]?.body).toMatchObject({ challengeToken: "chal-2" })
  })

  it("waits as long as the server says when a resend is rate limited", async () => {
    const ctx = setup()
    await toEmailCode(ctx)
    await ctx.clock.advance(60_000)
    ctx.server.on("/sendEmailCode", apiError(420, "FLOOD", { "retry-after": "120" }))
    await ctx.model.resendCode()
    expect(ctx.model.error.get()).toEqual({ kind: "rateLimited", retryAfterSeconds: 120 })
    expect(ctx.model.resendSeconds.get()).toBe(120)
    expect(ctx.model.step.get()).toBe("code")
  })
})

describe("back navigation", () => {
  it("returns to the right earlier step from every step before sign-in", async () => {
    const ctx = setup()
    const { model, server } = ctx

    await model.back()
    expect(model.step.get()).toBe("welcome")

    model.choosePhone()
    await model.back()
    expect(model.step.get()).toBe("welcome")
    expect(model.method.get()).toBeNull()

    model.chooseEmail()
    await model.back()
    expect(model.step.get()).toBe("welcome")

    await toEmailCode(ctx, { needsInviteCode: true })
    expect(model.step.get()).toBe("invite")
    await model.back()
    expect(model.step.get()).toBe("email")

    server.on("/sendEmailCode", ok({ existingUser: false, needsInviteCode: true, challengeToken: "chal-3" }))
    await model.submitEmail("ada@example.com")
    server.on("/checkInviteCode", ok({ valid: true }))
    await model.submitInvite("A7K2PQ9X")
    expect(model.step.get()).toBe("code")
    await model.back()
    expect(model.step.get()).toBe("invite")
    expect(model.inviteCode.get()).toBe("A7K2PQ9X")
    await model.back()
    expect(model.step.get()).toBe("email")
    await model.back()
    expect(model.step.get()).toBe("welcome")
  })

  it("returns from the code step to the contact step", async () => {
    const ctx = setup()
    await toEmailCode(ctx)
    ctx.server.on("/verifyEmailCode", apiError(400, "EMAIL_CODE_INVALID"))
    await ctx.model.submitCode("1")
    expect(ctx.model.error.get()).not.toBeNull()
    await ctx.model.back()
    expect(ctx.model.step.get()).toBe("email")
    expect(ctx.model.error.get()).toBeNull()
  })

  it("leaves the provider step and drops the pending attempt", async () => {
    const ctx = setup()
    await ctx.model.startProvider("google")
    expect(ctx.model.step.get()).toBe("provider")
    expect(ctx.attempts.load()).not.toBeNull()
    await ctx.model.back()
    expect(ctx.model.step.get()).toBe("welcome")
    expect(ctx.attempts.load()).toBeNull()
  })

  it("signs out when going back after authentication, from setup and from done", async () => {
    for (const pendingSetup of [true, false]) {
      const ctx = setup()
      await toEmailCode(ctx)
      ctx.server.on("/verifyEmailCode", ok(loginResult({ pendingSetup })))
      await ctx.model.submitCode("123456")
      expect(ctx.model.step.get()).toBe(pendingSetup ? "setup" : "done")

      ctx.server.on("/logout", ok())
      const backing = ctx.model.back()
      expect(ctx.model.pending.get()).toBe("signOut")
      expect(ctx.model.canGoBack.get()).toBe(false)
      await backing
      expect(ctx.server.to("/logout")[0]?.headers["authorization"]).toBe(`Bearer ${SECRET_TOKEN}`)
      expect(ctx.authStore.isLoggedIn()).toBe(false)
      expect(ctx.model.step.get()).toBe("welcome")
      expect(ctx.model.signedInUserId.get()).toBeNull()
      expect(ctx.model.pending.get()).toBeNull()
    }
  })
})

describe("stale and repeated requests", () => {
  it("ignores a slow send for a step the user left", async () => {
    const ctx = setup()
    const reply = hold()
    ctx.server.on("/sendEmailCode", reply)
    ctx.model.chooseEmail()
    const sending = ctx.model.submitEmail("ada@example.com")
    expect(ctx.model.pending.get()).toBe("sendCode")

    await ctx.model.back()
    expect(ctx.model.step.get()).toBe("welcome")
    expect(ctx.model.pending.get()).toBeNull()

    reply.resolve(ok({ existingUser: true, needsInviteCode: false, challengeToken: "late" }))
    await sending
    expect(ctx.model.step.get()).toBe("welcome")
    expect(ctx.model.error.get()).toBeNull()
    expect(ctx.model.contact.get()).toBeNull()
  })

  it("revokes a session that arrives after the user went back, without signing in", async () => {
    const ctx = setup()
    await toEmailCode(ctx)
    const reply = hold()
    ctx.server.on("/verifyEmailCode", reply)
    ctx.server.on("/logout", ok())
    const verifying = ctx.model.submitCode("123456")
    await ctx.model.back()
    expect(ctx.model.step.get()).toBe("email")

    reply.resolve(ok(loginResult()))
    await verifying
    await flushMicrotasks()
    expect(ctx.authStore.isLoggedIn()).toBe(false)
    expect(ctx.model.signedInUserId.get()).toBeNull()
    expect(ctx.model.step.get()).toBe("email")
    expect(ctx.server.to("/logout")[0]?.headers["authorization"]).toBe(`Bearer ${SECRET_TOKEN}`)
  })

  it("ignores a late failure after the user went back", async () => {
    const ctx = setup()
    await toEmailCode(ctx)
    const reply = hold()
    ctx.server.on("/verifyEmailCode", reply)
    const verifying = ctx.model.submitCode("123456")
    await ctx.model.back()
    reply.resolve(apiError(400, "EMAIL_CODE_INVALID"))
    await verifying
    expect(ctx.model.error.get()).toBeNull()
  })

  it("makes double submission impossible", async () => {
    const ctx = setup()
    ctx.model.chooseEmail()
    const reply = hold()
    ctx.server.on("/sendEmailCode", reply)
    const first = ctx.model.submitEmail("ada@example.com")
    const second = ctx.model.submitEmail("ada@example.com")
    ctx.model.choosePhone()
    reply.resolve(ok({ existingUser: true, needsInviteCode: false, challengeToken: "chal-1" }))
    await Promise.all([first, second])
    expect(ctx.server.to("/sendEmailCode")).toHaveLength(1)
    expect(ctx.model.step.get()).toBe("code")

    const verify = hold()
    ctx.server.on("/verifyEmailCode", verify)
    const a = ctx.model.submitCode("123456")
    const b = ctx.model.submitCode("123456")
    const c = ctx.model.resendCode()
    verify.resolve(ok(loginResult()))
    await Promise.all([a, b, c])
    expect(ctx.server.to("/verifyEmailCode")).toHaveLength(1)
    expect(ctx.server.to("/sendEmailCode")).toHaveLength(1)
    expect(ctx.model.step.get()).toBe("done")
  })
})

describe("network failures", () => {
  it("reports a network failure on the same step and succeeds on retry", async () => {
    const ctx = setup()
    ctx.model.chooseEmail()
    ctx.server.on(
      "/sendEmailCode",
      networkFailure,
      ok({ existingUser: true, needsInviteCode: false, challengeToken: "chal-1" }),
    )
    await ctx.model.submitEmail("ada@example.com")
    expect(ctx.model.step.get()).toBe("email")
    expect(ctx.model.error.get()).toEqual({ kind: "network" })

    await ctx.model.submitEmail("ada@example.com")
    expect(ctx.model.step.get()).toBe("code")
  })

  it("fails a request that outlives the timeout as a network error", async () => {
    const ctx = setup()
    await toEmailCode(ctx)
    ctx.server.on("/verifyEmailCode", hold())
    const verifying = ctx.model.submitCode("123456")
    await ctx.clock.advance(20_000)
    await verifying
    expect(ctx.model.error.get()).toEqual({ kind: "network" })
    expect(ctx.model.pending.get()).toBeNull()
    expect(ctx.model.step.get()).toBe("code")
  })
})

describe("provider sign-in", () => {
  const challengeOf = (url: string) => new URL(url).searchParams.get("code_challenge")!

  it("builds the start URL, checks the state on return and redeems", async () => {
    const ctx = setup()
    const url = await ctx.model.startProvider("google")
    expect(url).not.toBeNull()
    const start = new URL(url!)
    expect(`${start.origin}${start.pathname}`).toBe(`${API_BASE}/auth/provider/start`)
    expect(Object.fromEntries(start.searchParams)).toEqual({
      provider: "google",
      purpose: "app",
      return_to: RETURN_URL,
      code_challenge: expect.stringMatching(/^[A-Za-z0-9_-]{43}$/),
      client_type: "web",
      device_id: device.deviceId,
      client_version: "1.2.3",
      device_name: "Chrome on macOS",
      timezone: "Europe/Berlin",
    })
    expect(ctx.model.step.get()).toBe("provider")
    expect(ctx.model.method.get()).toBe("google")
    expect(ctx.server.requests).toHaveLength(0)

    // The tab navigates away and comes back: a fresh model on the same storage.
    const reloaded = createSignInModel({
      api: ctx.api,
      authStore: ctx.authStore,
      clock: ctx.clock,
      provider: {
        crypto: globalThis.crypto,
        attempts: new ProviderAttemptStore(ctx.sessionStorage),
        apiBaseUrl: API_BASE,
        returnUrl: RETURN_URL,
        device: () => device,
      },
    })
    ctx.server.on("/auth/provider/redeem", ok(loginResult({ pendingSetup: true })))
    await ctx.clock.advance(90_000)
    await reloaded.completeProvider(`${RETURN_URL}?ticket=T1CKET&code_challenge=${challengeOf(url!)}`)

    const redeem = ctx.server.to("/auth/provider/redeem")[0]
    const body = redeem?.body as { ticket: string; code_verifier: string }
    expect(Object.keys(body).sort()).toEqual(["code_verifier", "ticket"])
    expect(body.ticket).toBe("T1CKET")
    expect(await codeChallengeFor(globalThis.crypto, body.code_verifier)).toBe(challengeOf(url!))
    expect(reloaded.step.get()).toBe("setup")
    expect(reloaded.method.get()).toBe("google")
    expect(ctx.authStore.getState().currentUserId).toBe("42")
    expect(ctx.sessionStorage.values.size).toBe(0)
  })

  it("rejects a mismatched state without redeeming", async () => {
    const ctx = setup()
    const url = await ctx.model.startProvider("apple")
    const other = "A".repeat(43)
    expect(challengeOf(url!)).not.toBe(other)
    await ctx.model.completeProvider(`${RETURN_URL}?ticket=T1CKET&code_challenge=${other}`)
    expect(ctx.model.step.get()).toBe("provider")
    expect(ctx.model.error.get()).toEqual({ kind: "providerStateMismatch" })
    expect(ctx.server.requests).toHaveLength(0)
    expect(ctx.attempts.load()).toBeNull()
    expect(ctx.authStore.isLoggedIn()).toBe(false)
  })

  it("rejects a return with no pending attempt or an expired one", async () => {
    const ctx = setup()
    await ctx.model.completeProvider(`${RETURN_URL}?ticket=T&code_challenge=${"B".repeat(43)}`)
    expect(ctx.model.error.get()).toEqual({ kind: "providerStateMismatch" })

    const fresh = setup()
    const url = await fresh.model.startProvider("google")
    await fresh.clock.advance(15 * 60_000 + 1)
    await fresh.model.completeProvider(`${RETURN_URL}?ticket=T&code_challenge=${challengeOf(url!)}`)
    expect(fresh.model.error.get()).toEqual({ kind: "providerStateMismatch" })
    expect(fresh.server.requests).toHaveLength(0)
  })

  it("shows a cancelled sign-in as its own state and does not redirect", async () => {
    const ctx = setup()
    const url = await ctx.model.startProvider("google")
    await ctx.model.completeProvider(`${RETURN_URL}?error=cancelled&code_challenge=${challengeOf(url!)}`)
    expect(ctx.model.step.get()).toBe("provider")
    expect(ctx.model.error.get()).toEqual({ kind: "providerCancelled" })
    expect(ctx.server.requests).toHaveLength(0)

    // Trying again from the provider step starts a new attempt.
    const retry = await ctx.model.startProvider("google")
    expect(retry).not.toBeNull()
    expect(challengeOf(retry!)).not.toBe(challengeOf(url!))
  })

  it("reports a rejected ticket", async () => {
    const ctx = setup()
    const url = await ctx.model.startProvider("google")
    ctx.server.on("/auth/provider/redeem", {
      status: 401,
      body: { error: "invalid_ticket", error_description: "Ticket is invalid or expired." },
    })
    await ctx.model.completeProvider(`${RETURN_URL}?ticket=T&code_challenge=${challengeOf(url!)}`)
    expect(ctx.model.error.get()).toEqual({ kind: "invalidTicket" })
    expect(ctx.model.step.get()).toBe("provider")
  })

  it("does nothing for a URL without hand-off parameters", async () => {
    const ctx = setup()
    await ctx.model.completeProvider("https://app.test/")
    expect(ctx.model.step.get()).toBe("welcome")
  })

  it("fails to start when the attempt cannot be stored", async () => {
    const ctx = setup()
    ctx.sessionStorage.failing = true
    expect(await ctx.model.startProvider("google")).toBeNull()
    expect(ctx.model.step.get()).toBe("welcome")
    expect(ctx.model.error.get()).toEqual({ kind: "providerFailed" })
  })
})

describe("secrets", () => {
  it("never puts a code, token or ticket into model state other than the session", async () => {
    const ctx = setup()
    await toEmailCode(ctx)
    ctx.server.on("/verifyEmailCode", apiError(400, "EMAIL_CODE_INVALID"))
    await ctx.model.submitCode("987654")
    const visible = JSON.stringify({
      error: ctx.model.error.get(),
      contact: ctx.model.contact.get(),
      step: ctx.model.step.get(),
    })
    expect(visible).not.toContain("987654")
    expect(visible).not.toContain("chal-1")
    expect(visible).not.toContain("Server description text")
  })
})
