import { useEffect, useState } from "react"
import { useNavigate } from "@tanstack/react-router"
import { apiRequest } from "@/lib/api"
import { Button } from "@/components/ui/button"
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { useAdmin } from "@/state/admin"

export const LoginPage = () => {
  const { session, refresh } = useAdmin()
  const navigate = useNavigate()
  const [showEmailCode, setShowEmailCode] = useState(false)
  const [email, setEmail] = useState("")
  const [code, setCode] = useState("")
  const [challengeToken, setChallengeToken] = useState<string | null>(null)
  const [password, setPassword] = useState("")
  const [totp, setTotp] = useState("")
  const [stage, setStage] = useState<"email" | "code">("email")
  const [message, setMessage] = useState<string | null>(null)
  const [isBusy, setIsBusy] = useState(false)

  useEffect(() => {
    if (session) {
      void navigate({ to: "/", replace: true })
    }
  }, [navigate, session])

  const sendCode = async () => {
    setIsBusy(true)
    setMessage(null)
    const data = await apiRequest<{ challengeToken?: string }>("/admin/auth/send-email-code", {
      method: "POST",
      body: JSON.stringify({ email }),
    })

    if (data.ok) {
      setChallengeToken(typeof data.challengeToken === "string" ? data.challengeToken : null)
      setStage("code")
      setMessage("If this email is allowed, a code was sent.")
    } else {
      setMessage("Unable to send code. Try again.")
    }
    setIsBusy(false)
  }

  const verifyCode = async () => {
    setIsBusy(true)
    setMessage(null)
    const data = await apiRequest("/admin/auth/verify-email-code", {
      method: "POST",
      body: JSON.stringify({ email, code, challengeToken }),
    })

    if (data.ok) {
      await refresh()
      setMessage(null)
    } else {
      setMessage(data.error === "password_required" ? "Use password login for this account." : "Invalid code.")
    }
    setIsBusy(false)
  }

  const passwordLogin = async () => {
    setIsBusy(true)
    setMessage(null)
    const data = await apiRequest("/admin/auth/login", {
      method: "POST",
      body: JSON.stringify({ email, password, totpCode: totp }),
    })

    if (data.ok) {
      await refresh()
      setMessage(null)
    } else {
      if (data.error === "password_not_set") {
        setShowEmailCode(true)
        setMessage("Password not set yet. Use email code to set it up.")
      } else if (data.error === "login_locked") {
        setMessage("Too many attempts. Try again in 15 minutes.")
      } else {
        setMessage("Login failed. Check credentials.")
      }
    }
    setIsBusy(false)
  }

  return (
    <div className="min-h-screen bg-background text-foreground">
      <div className="mx-auto flex min-h-screen w-full max-w-lg items-center px-6">
        <Card className="w-full">
          <CardHeader>
            <div className="mb-2 flex items-center gap-2 text-sm">
              <div className="rounded-full bg-foreground px-2 py-1">
                <img src="/logotype-white.svg" alt="Inline" className="h-4 w-auto" />
              </div>
              <span className="font-semibold text-foreground">Admin</span>
            </div>
            <CardTitle>Admin sign in</CardTitle>
            <p className="text-xs text-muted-foreground">Use your superadmin credentials.</p>
          </CardHeader>
          <CardContent className="flex flex-col gap-5 text-sm">
            <div className="flex flex-col gap-3">
              <div className="flex flex-col gap-2">
                <Label>Email</Label>
                <Input
                  type="email"
                  value={email}
                  onChange={(event) => setEmail(event.target.value)}
                  placeholder="founder@inline.chat"
                />
              </div>
              <div className="flex flex-col gap-2">
                <Label>Password</Label>
                <Input
                  type="password"
                  value={password}
                  onChange={(event) => setPassword(event.target.value)}
                />
              </div>
              <div className="flex flex-col gap-2">
                <Label>One-time password</Label>
                <Input type="text" value={totp} onChange={(event) => setTotp(event.target.value)} placeholder="123456" />
              </div>
              <Button onClick={passwordLogin} disabled={!email || !password || isBusy}>
                {isBusy ? "Signing in..." : "Sign in"}
              </Button>
            </div>

            {showEmailCode && (
              <div className="rounded-[var(--radius)] border border-border bg-muted/40 p-4">
                <div className="mb-3 text-xs font-semibold uppercase tracking-[0.2em] text-muted-foreground">
                  First-time setup
                </div>
                {stage === "email" && (
                  <div className="flex flex-col gap-3">
                    <Label>Email</Label>
                    <Input
                      type="email"
                      value={email}
                      onChange={(event) => setEmail(event.target.value)}
                      placeholder="founder@inline.chat"
                    />
                    <Button onClick={sendCode} disabled={!email || isBusy}>
                      {isBusy ? "Sending..." : "Send code"}
                    </Button>
                  </div>
                )}

                {stage === "code" && (
                  <div className="flex flex-col gap-3">
                    <Label>Code</Label>
                    <Input type="text" value={code} onChange={(event) => setCode(event.target.value)} placeholder="123456" />
                    <div className="flex gap-2">
                      <Button onClick={verifyCode} disabled={!code || isBusy}>
                        {isBusy ? "Verifying..." : "Verify"}
                      </Button>
                      <Button
                        variant="ghost"
                        onClick={() => {
                          setStage("email")
                          setChallengeToken(null)
                        }}
                      >
                        Use different email
                      </Button>
                    </div>
                  </div>
                )}
              </div>
            )}

            {!showEmailCode && (
              <Button variant="ghost" onClick={() => setShowEmailCode(true)} className="justify-start px-0 text-xs">
                First time here? Use an email code to set your password.
              </Button>
            )}

            {message && <p className="text-xs text-muted-foreground">{message}</p>}
          </CardContent>
        </Card>
      </div>
    </div>
  )
}
