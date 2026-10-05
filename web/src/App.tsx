import { useEffect, useRef, useState, useSyncExternalStore } from "react"
import { AuthStore, BrowserAuthSessionPersistence } from "@inline/auth/core"
import { setConfig } from "@inline/config"
import type { Account } from "./core"
import type { AccountView } from "./AccountView"
import { AuthApi } from "./auth/api"
import { Boot, Logo } from "./Boot"

const serverUrl = __INLINE_API_ORIGIN__.replace(/\/+$/, "")
setConfig({
  serverUrl,
  apiBaseUrl: `${serverUrl}/v1`,
  realtimeUrl: `${serverUrl.replace(/^http/, "ws")}/realtime`,
})
const api = new AuthApi(import.meta.env.DEV ? window.location.origin : serverUrl)

export function App() {
  const [auth] = useState(
    () =>
      new AuthStore({
        storage: new BrowserAuthSessionPersistence(`inline-web:${serverUrl}`),
      })
  )
  const state = useSyncExternalStore(
    (listener) => auth.subscribe(() => listener()),
    auth.getSnapshot,
    auth.getSnapshot
  )
  const [account, setAccount] = useState<{
    core: Account
    token: string
    key: string
    View: typeof AccountView
  } | null>(null)
  const [reauthenticate, setReauthenticate] = useState(false)
  const [lifetimeError, setLifetimeError] = useState("")
  useEffect(() => {
    if (
      !state.currentUserId ||
      !state.token ||
      state.storageStatus !== "ready" ||
      reauthenticate ||
      lifetimeError
    )
      return
    // Sign-in needs only auth persistence. Load the account and conversation
    // runtime after hydration, and ignore a load completed for a retired session.
    let active = true
    let next: Account | undefined
    const { currentUserId, token } = state
    void Promise.all([import("./core"), import("./AccountView")])
      .then(([{ Account }, { AccountView }]) => {
        if (!active) return
        next = new Account(currentUserId, { auth, serverUrl })
        setAccount({
          core: next,
          token,
          key: crypto.randomUUID(),
          View: AccountView,
        })
        void next.start().catch(() => undefined)
      })
      .catch((error: unknown) => {
        if (active)
          setLifetimeError(
            error instanceof Error ? error.message : "Inline could not load your conversations."
          )
      })
    return () => {
      active = false
      setAccount(null)
      void next?.stop().catch((error: unknown) => {
        setLifetimeError(
          error instanceof Error
            ? error.message
            : "Inline could not safely close its local messages."
        )
      })
    }
  }, [auth, state.currentUserId, state.token, state.storageStatus, reauthenticate, lifetimeError])

  if (lifetimeError)
    return (
      <main className="boot">
        <Logo />
        <h1>Inline needs to reopen its local messages</h1>
        <p role="alert">{lifetimeError}</p>
        <p>Your saved session is preserved. Reload to reopen Inline.</p>
        <p>Draft edits that could not be saved may be lost when you reload.</p>
        <button className="primary" onClick={() => window.location.reload()}>
          Reload Inline
        </button>
      </main>
    )
  if (!state.hasHydrated) return <Boot text="Opening Inline…" />
  if (state.storageStatus === "unavailable")
    return (
      <main className="boot">
        <Logo />
        <h1>Your browser storage is unavailable</h1>
        <p>
          Inline needs local storage to keep your session and messages safely. Your existing session
          has been preserved.
        </p>
        <button
          className="primary"
          onClick={() => {
            if (state.token && state.currentUserId)
              void auth.login({
                token: state.token,
                userId: state.currentUserId,
              })
            else void auth.refreshFromStorage()
          }}
        >
          Try again
        </button>
      </main>
    )
  if (!state.token || !state.currentUserId || reauthenticate)
    return (
      <Login
        auth={auth}
        onComplete={() => setReauthenticate(false)}
        onCancel={state.token ? () => setReauthenticate(false) : undefined}
      />
    )
  if (!account || account.core.accountId !== state.currentUserId || account.token !== state.token)
    return <Boot text="Opening your conversations…" />
  const View = account.View
  return (
    <View key={account.key} account={account.core} onSignInAgain={() => setReauthenticate(true)} />
  )
}

function Login({
  auth,
  onComplete,
  onCancel,
}: {
  auth: AuthStore
  onComplete: () => void
  onCancel?: () => void
}) {
  const mounted = useRef(true)
  useEffect(() => {
    mounted.current = true
    return () => {
      mounted.current = false
    }
  }, [])
  const [email, setEmail] = useState("")
  const [code, setCode] = useState("")
  const [challenge, setChallenge] = useState<string>()
  const [step, setStep] = useState<"email" | "code">("email")
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState("")
  const run = async (resend = false) => {
    if (busy) return
    setBusy(true)
    setError("")
    try {
      if (step === "email" || resend) {
        setChallenge(await api.sendCode(email.trim()))
        setStep("code")
      } else {
        const sessionBefore = auth.getState()
        const session = await api.verify(email.trim(), code.trim(), challenge)
        if (
          !mounted.current ||
          auth.getState().token !== sessionBefore.token ||
          auth.getState().currentUserId !== sessionBefore.currentUserId
        )
          return
        await auth.login(session)
        if (mounted.current) onComplete()
      }
    } catch (reason) {
      setError(
        reason instanceof Error && reason.name !== "TimeoutError"
          ? reason.message
          : "The request timed out. Please try again."
      )
    } finally {
      setBusy(false)
    }
  }
  return (
    <div className="login-page">
      <div className="login-brand">
        <Logo />
        <span>Inline</span>
      </div>
      <main className="login-card">
        <h1>{step === "email" ? "Your work, in conversation." : "Check your inbox"}</h1>
        <p>
          {step === "email"
            ? "Sign in to your threads, spaces, and people."
            : `Enter the verification code sent to ${email.trim()}.`}
        </p>
        <form
          onSubmit={(event) => {
            event.preventDefault()
            void run()
          }}
        >
          <label htmlFor="login-input">
            {step === "email" ? "Email address" : "Verification code"}
          </label>
          {step === "email" ? (
            <input
              id="login-input"
              type="email"
              autoComplete="email"
              autoFocus
              required
              value={email}
              onChange={(e) => setEmail(e.target.value)}
              placeholder="you@company.com"
              disabled={busy}
            />
          ) : (
            <input
              id="login-input"
              autoComplete="one-time-code"
              inputMode="numeric"
              autoFocus
              required
              value={code}
              onChange={(e) => setCode(e.target.value)}
              placeholder="Enter your code"
              disabled={busy}
            />
          )}{" "}
          {error && (
            <p className="error" role="alert">
              {error}
            </p>
          )}
          <button
            type="submit"
            className="primary"
            disabled={busy || (step === "code" && !code.trim())}
          >
            {busy ? "Please wait…" : step === "email" ? "Continue with email" : "Sign in"}
            <span aria-hidden="true">→</span>
          </button>
        </form>
        {step === "code" && (
          <div className="login-actions">
            <button disabled={busy} onClick={() => void run(true)}>
              Resend code
            </button>
            <button
              disabled={busy}
              onClick={() => {
                setStep("email")
                setCode("")
                setError("")
              }}
            >
              Change email
            </button>
          </div>
        )}
        {onCancel && (
          <button className="return-to-account" disabled={busy} onClick={onCancel}>
            Back to saved conversations
          </button>
        )}
        <p className="login-legal">
          By continuing, you agree to Inline’s{" "}
          <a href="https://inline.chat/legal/terms" target="_blank" rel="noreferrer">
            Terms
          </a>{" "}
          and{" "}
          <a href="https://inline.chat/legal/privacy" target="_blank" rel="noreferrer">
            Privacy Policy
          </a>
          .
        </p>
      </main>
      <footer className="login-footer">Inline web · Early access</footer>
    </div>
  )
}
