import { useEffect, useState } from "react"
import { useNavigate } from "@tanstack/react-router"
import { apiRequest } from "@/lib/api"
import { Button } from "@/components/ui/button"
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { useAdmin } from "@/state/admin"

export const SetupPage = () => {
  const { session, refresh, needsSetup } = useAdmin()
  const navigate = useNavigate()
  const [password, setPassword] = useState("")
  const [confirmPassword, setConfirmPassword] = useState("")
  const [totpSecret, setTotpSecret] = useState<string | null>(null)
  const [totpUrl, setTotpUrl] = useState<string | null>(null)
  const [totpCode, setTotpCode] = useState("")
  const [message, setMessage] = useState<string | null>(null)
  const [isBusy, setIsBusy] = useState(false)

  useEffect(() => {
    if (!session) {
      void navigate({ to: "/login", replace: true })
    }
  }, [navigate, session])

  useEffect(() => {
    if (session && !needsSetup) {
      void navigate({ to: "/", replace: true })
    }
  }, [navigate, needsSetup, session])

  const setAdminPassword = async () => {
    setIsBusy(true)
    setMessage(null)

    if (password.length < 12) {
      setMessage("Password should be at least 12 characters.")
      setIsBusy(false)
      return
    }

    if (password !== confirmPassword) {
      setMessage("Passwords do not match.")
      setIsBusy(false)
      return
    }

    const data = await apiRequest("/admin/auth/set-password", {
      method: "POST",
      body: JSON.stringify({ password }),
    })

    if (data.ok) {
      setPassword("")
      setConfirmPassword("")
      await refresh()
    } else {
      setMessage("Failed to set password.")
    }

    setIsBusy(false)
  }

  const setupTotp = async () => {
    setIsBusy(true)
    setMessage(null)
    const data = await apiRequest<{ secret: string; otpauthUrl: string }>("/admin/auth/totp/setup", {
      method: "GET",
    })

    if (data.ok) {
      setTotpSecret(data.secret)
      setTotpUrl(data.otpauthUrl)
    } else {
      setMessage("Unable to start TOTP setup.")
    }
    setIsBusy(false)
  }

  const verifyTotp = async () => {
    setIsBusy(true)
    setMessage(null)
    const data = await apiRequest("/admin/auth/totp/verify", {
      method: "POST",
      body: JSON.stringify({ code: totpCode }),
    })

    if (data.ok) {
      setTotpCode("")
      await refresh()
    } else {
      setMessage("Invalid code. Try again.")
    }
    setIsBusy(false)
  }

  if (!session) return null

  return (
    <div className="min-h-screen bg-background text-foreground">
      <div className="mx-auto flex min-h-screen w-full max-w-2xl items-center px-6">
        <Card className="w-full">
          <CardHeader>
            <div className="mb-2 flex items-center gap-2 text-sm">
              <div className="rounded-full bg-foreground px-2 py-1">
                <img src="/logotype-white.svg" alt="Inline" className="h-4 w-auto" />
              </div>
              <span className="font-semibold text-foreground">Admin</span>
            </div>
            <CardTitle>Secure your admin access</CardTitle>
            <p className="text-xs text-muted-foreground">
              Finish setup before you can access admin tools.
            </p>
          </CardHeader>
          <CardContent className="flex flex-col gap-8 text-sm">
            {!session.setup.passwordSet && (
              <div className="flex flex-col gap-3">
                <h3 className="text-sm font-semibold">Set a long admin password</h3>
                <Label>Password</Label>
                <Input type="password" value={password} onChange={(event) => setPassword(event.target.value)} />
                <Label>Confirm password</Label>
                <Input
                  type="password"
                  value={confirmPassword}
                  onChange={(event) => setConfirmPassword(event.target.value)}
                />
                <Button onClick={setAdminPassword} disabled={isBusy}>
                  {isBusy ? "Saving..." : "Save password"}
                </Button>
              </div>
            )}

            {session.setup.passwordSet && !session.setup.totpEnabled && (
              <div className="flex flex-col gap-3">
                <h3 className="text-sm font-semibold">Enable TOTP</h3>
                {!totpSecret ? (
                  <Button variant="secondary" onClick={setupTotp} disabled={isBusy}>
                    {isBusy ? "Generating..." : "Generate TOTP secret"}
                  </Button>
                ) : (
                  <div className="flex flex-col gap-2">
                    <p className="text-xs text-muted-foreground">Use your authenticator app to add:</p>
                    <div className="rounded-[var(--radius)] border border-border bg-muted px-3 py-2 text-sm">
                      {totpSecret}
                    </div>
                    {totpUrl && (
                      <a className="text-xs text-primary underline" href={totpUrl}>
                        Open in authenticator
                      </a>
                    )}
                    <Label>Enter a code to confirm</Label>
                    <Input value={totpCode} onChange={(event) => setTotpCode(event.target.value)} placeholder="123456" />
                    <Button onClick={verifyTotp} disabled={!totpCode || isBusy}>
                      {isBusy ? "Verifying..." : "Confirm TOTP"}
                    </Button>
                  </div>
                )}
              </div>
            )}

            {message && <p className="text-xs text-muted-foreground">{message}</p>}
          </CardContent>
        </Card>
      </div>
    </div>
  )
}
