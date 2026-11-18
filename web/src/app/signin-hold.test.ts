import { AuthStore } from "@inline/auth/core"
import { createSignInApi, createSignInModel, type SignInModel } from "@inline/auth/flows"
import type { UserID } from "@inline/ids"
import { createFakePlatform } from "@inline/platform/testing"
import { manualTime, signal } from "@inline/reactive"
import { describe, expect, it } from "vitest"
import { createBootMetrics } from "./perf"
import { AppRuntime } from "./runtime"
import { LazySignIn } from "./signin-loader"
import { coreHarness, fakePerformance, manualPaints, memoryStorage, microtasks, sharedAuthStorage, type CoreHarness } from "./test-fixtures"

/**
 * The gate rule for a new account (Mac: profile setup comes before the main
 * window). The auth store logs in inside the sign-in model's last request,
 * so the app model starts the session at once; the sign-in screen must stay
 * up while the model is at `setup`, and give way to the shell when the user
 * continues (`done`) or backs out (sign-out). An existing account (`done`
 * straight away) goes to the shell at once.
 */

/** A sign-in server for user 42: a new account (`pendingSetup`) or an existing one. */
const signInServer = (newAccount: boolean) => async (url: string) => {
  const json = (result: unknown) =>
    new Response(JSON.stringify({ ok: true, result }), { status: 200, headers: { "content-type": "application/json" } })
  if (url.endsWith("/sendEmailCode")) return json({ existingUser: !newAccount, needsInviteCode: false, challengeToken: "c1" })
  if (url.endsWith("/verifyEmailCode")) {
    return json({ userId: "42", token: "t42", user: { id: "42", firstName: "Ada", pendingSetup: newAccount } })
  }
  if (url.endsWith("/logout")) return json({})
  return new Response(JSON.stringify({ ok: false, error: "NOT_FOUND" }), { status: 404 })
}

const setup = (newAccount: boolean) => {
  const time = manualTime()
  const authStore = new AuthStore({ storage: sharedAuthStorage().tab() })
  const cores: CoreHarness[] = []
  const api = createSignInApi({
    fetch: signInServer(newAccount),
    apiBaseUrl: "https://api.test/v1",
    device: { deviceId: "d1", deviceName: "Test" },
  })
  const models: SignInModel[] = []
  const runtime = new AppRuntime<LazySignIn>({
    authStore,
    createSignIn: (deps) =>
      new LazySignIn(async () => {
        const model = createSignInModel({ api, authStore, clock: time, signOut: deps.signOut })
        models.push(model)
        return model
      }),
    signInHold: {
      held: (signIn, userId) => signIn.held.get() && signIn.signedInUserId() === userId,
      release: (signIn) => signIn.release(),
    },
    connect: () => {
      const harness = coreHarness(time)
      cores.push(harness)
      return harness.connection
    },
    platform: createFakePlatform().platform,
    keyboardPlatform: { os: "mac", surface: "browser" },
    clock: time,
    metrics: createBootMetrics({ performance: fakePerformance(), afterPaint: manualPaints().afterPaint }),
    storage: memoryStorage(),
  })
  const settle = async () => {
    await authStore.ready
    await microtasks()
    time.frame()
    await microtasks()
  }
  const signInModel = () => {
    const phase = runtime.app.phase.peek()
    if (phase.kind !== "signedOut") throw new Error(`expected sign-in, got ${phase.kind}`)
    const model = phase.signIn.model.peek()
    if (!model) throw new Error("sign-in model not loaded")
    return { lazy: phase.signIn, model }
  }
  const signIn = async () => {
    const { lazy, model } = signInModel()
    model.chooseEmail()
    await model.submitEmail("ada@example.com")
    await model.submitCode("123456")
    await settle()
    return { lazy, model }
  }
  return { runtime, authStore, cores, models, settle, signIn, signInModel, phase: () => runtime.app.phase.peek().kind }
}

describe("a new account's setup", () => {
  it("stays on screen over the started session until the user continues, then the shell shows", async () => {
    const s = setup(true)
    await s.settle()
    const { lazy, model } = await s.signIn()
    // The session started behind the screen: the core is connecting already.
    expect(s.phase()).toBe("signedIn")
    expect(s.cores).toHaveLength(1)
    expect(model.step.peek()).toBe("setup")
    expect(s.runtime.heldSignIn.peek()).toBe(lazy)
    expect(lazy.model.peek()).toBe(model)

    model.finishSetup()
    await microtasks()
    expect(s.runtime.heldSignIn.peek()).toBeUndefined()
    expect(lazy.model.peek()).toBeUndefined()
    expect(s.phase()).toBe("signedIn")
  })

  it("an existing account goes to the shell at once (done is not held)", async () => {
    const s = setup(false)
    await s.settle()
    const { lazy, model } = await s.signIn()
    expect(model.step.peek()).toBe("done")
    expect(s.phase()).toBe("signedIn")
    expect(s.runtime.heldSignIn.peek()).toBeUndefined()
    expect(lazy.model.peek()).toBeUndefined()
  })

  it("backing out of setup signs out here, with no notice, and lets the sign-in go", async () => {
    const s = setup(true)
    await s.settle()
    const { lazy, model } = await s.signIn()
    expect(s.runtime.heldSignIn.peek()).toBe(lazy)
    await model.back()
    await s.runtime.idle()
    await s.settle()
    expect(s.phase()).toBe("signedOut")
    expect(s.runtime.heldSignIn.peek()).toBeUndefined()
    expect(s.runtime.signedOutReason.peek()).toBeUndefined()
    expect(lazy.model.peek()).toBeUndefined()
    // A fresh sign-in for the next account.
    expect(s.signInModel().lazy).not.toBe(lazy)
  })

  it("the account ending elsewhere during setup releases the held sign-in", async () => {
    const s = setup(true)
    await s.settle()
    const { lazy } = await s.signIn()
    expect(s.runtime.heldSignIn.peek()).toBe(lazy)
    await s.authStore.logout()
    await s.runtime.idle()
    await s.settle()
    expect(s.phase()).toBe("signedOut")
    expect(s.runtime.heldSignIn.peek()).toBeUndefined()
    expect(lazy.model.peek()).toBeUndefined()
  })
})

describe("LazySignIn", () => {
  const fakeModel = () => {
    const step = signal("welcome")
    let disposed = 0
    return {
      model: { step, signedInUserId: signal<UserID | null>(null), dispose: () => void (disposed += 1) },
      disposed: () => disposed,
    }
  }

  it("publishes the model when the flows arrive, and retries after a failure", async () => {
    const fake = fakeModel()
    let fail = true
    const lazy = new LazySignIn(async () => {
      if (fail) throw new Error("offline")
      return fake.model
    })
    await microtasks()
    expect(lazy.model.peek()).toBeUndefined()
    expect(lazy.error.peek()).toBeInstanceOf(Error)
    fail = false
    lazy.retry()
    await microtasks()
    expect(lazy.error.peek()).toBeUndefined()
    expect(lazy.model.peek()).toBe(fake.model)
  })

  it("disposes a model that is not at setup, and one that arrives after it was let go", async () => {
    const fake = fakeModel()
    const lazy = new LazySignIn(async () => fake.model)
    await microtasks()
    lazy.dispose()
    await microtasks()
    expect(fake.disposed()).toBe(1)
    expect(lazy.held.peek()).toBe(false)

    const late = fakeModel()
    let resolve: ((model: typeof late.model) => void) | undefined
    const pending = new LazySignIn<typeof late.model>(() => new Promise((done) => (resolve = done)))
    pending.dispose()
    resolve?.(late.model)
    await microtasks()
    expect(late.disposed()).toBe(1)
    expect(pending.model.peek()).toBeUndefined()
  })
})
