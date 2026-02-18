import { useCallback, useEffect, useState } from "react"

type ApiResponse = {
  ok: boolean
  error?: string
  challengeToken?: string
  user?: {
    id: number
    email: string
  }
}

type ViewState = "checking" | "email" | "code" | "authed"

const API_BASE =
  (import.meta.env.VITE_ADMIN_API_BASE as string | undefined)?.replace(/\/$/, "") ??
  (import.meta.env.PROD ? "https://api.inline.chat" : "")

const request = async (path: string, init?: RequestInit) => {
  const response = await fetch(`${API_BASE}${path}`, {
    credentials: "include",
    headers: {
      "content-type": "application/json",
      ...(init?.headers ?? {}),
    },
    ...init,
  })
  let data: ApiResponse = { ok: false }
  try {
    data = (await response.json()) as ApiResponse
  } catch {
    data = { ok: false, error: "invalid_response" }
  }
  return { response, data }
}

export default function App() {
  const [view, setView] = useState<ViewState>("checking")
  const [email, setEmail] = useState("")
  const [code, setCode] = useState("")
  const [challengeToken, setChallengeToken] = useState<string | null>(null)
  const [message, setMessage] = useState<string | null>(null)
  const [currentUser, setCurrentUser] = useState<ApiResponse["user"] | null>(null)
  const [isBusy, setIsBusy] = useState(false)

  const checkSession = useCallback(async () => {
    setIsBusy(true)
    setMessage(null)
    const { data } = await request("/admin/me", { method: "GET" })
    if (data.ok && data.user) {
      setCurrentUser(data.user)
      setView("authed")
    } else {
      setCurrentUser(null)
      setChallengeToken(null)
      setView("email")
    }
    setIsBusy(false)
  }, [])

  useEffect(() => {
    void checkSession()
  }, [checkSession])

  const sendCode = async () => {
    setIsBusy(true)
    setMessage(null)
    const { data } = await request("/admin/auth/send-email-code", {
      method: "POST",
      body: JSON.stringify({ email }),
    })

    if (data.ok) {
      setChallengeToken(typeof data.challengeToken === "string" ? data.challengeToken : null)
      setView("code")
      setMessage("If this email is allowed, a code was sent.")
    } else {
      setMessage("Unable to send code. Try again.")
    }
    setIsBusy(false)
  }

  const verifyCode = async () => {
    setIsBusy(true)
    setMessage(null)
    const { data } = await request("/admin/auth/verify-email-code", {
      method: "POST",
      body: JSON.stringify({ email, code, challengeToken }),
    })

    if (data.ok && data.user) {
      setCurrentUser(data.user)
      setView("authed")
      setCode("")
      setMessage(null)
    } else {
      setMessage("Invalid code or not authorized.")
    }
    setIsBusy(false)
  }

  const logout = async () => {
    setIsBusy(true)
    await request("/admin/auth/logout", { method: "POST" })
    setCurrentUser(null)
    setChallengeToken(null)
    setView("email")
    setCode("")
    setIsBusy(false)
  }

  return (
    <div className="app">
      <header>
        <div>
          <p className="eyebrow">Inline</p>
          <h1>Admin Console</h1>
        </div>
        <div className="status">
          <span className={view === "authed" ? "dot online" : "dot"} />
          <span>{view === "authed" ? "Session active" : "Session required"}</span>
        </div>
      </header>

      <main>
        {view === "checking" && <div className="card">Checking session...</div>}

        {view === "email" && (
          <div className="card">
            <h2>Sign in</h2>
            <p>Use your Inline account email to request a login code.</p>
            <label>
              Email
              <input
                type="email"
                value={email}
                onChange={(event) => setEmail(event.target.value)}
                placeholder="name@inline.chat"
                autoComplete="email"
              />
            </label>
            <button onClick={sendCode} disabled={!email || isBusy}>
              {isBusy ? "Sending..." : "Send code"}
            </button>
            {message && <p className="message">{message}</p>}
          </div>
        )}

        {view === "code" && (
          <div className="card">
            <h2>Enter code</h2>
            <p>We sent a six-digit code to {email}.</p>
            <label>
              Code
              <input
                type="text"
                value={code}
                onChange={(event) => setCode(event.target.value)}
                inputMode="numeric"
                placeholder="123456"
              />
            </label>
            <div className="actions">
              <button onClick={verifyCode} disabled={!code || isBusy}>
                {isBusy ? "Verifying..." : "Verify"}
              </button>
              <button
                onClick={() => {
                  setChallengeToken(null)
                  setView("email")
                }}
                className="ghost"
              >
                Change email
              </button>
            </div>
            {message && <p className="message">{message}</p>}
          </div>
        )}

        {view === "authed" && (
          <div className="card">
            <h2>Welcome back</h2>
            <p className="muted">Signed in as {currentUser?.email}</p>
            <div className="actions">
              <button onClick={checkSession} disabled={isBusy}>
                {isBusy ? "Refreshing..." : "Refresh session"}
              </button>
              <button onClick={logout} className="ghost" disabled={isBusy}>
                Sign out
              </button>
            </div>
            <div className="divider" />
            <p className="muted">
              Admin metrics and user tools will appear here after the core auth flow is verified.
            </p>
          </div>
        )}
      </main>
    </div>
  )
}
