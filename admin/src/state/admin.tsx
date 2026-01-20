import React, { createContext, useCallback, useContext, useMemo, useState } from "react"
import { apiRequest } from "@/lib/api"

export type AdminUser = {
  id: number
  email: string
  firstName?: string | null
  lastName?: string | null
}

export type AdminSessionInfo = {
  user: AdminUser
  setup: {
    passwordSet: boolean
    totpEnabled: boolean
  }
  session: {
    stepUpAt: string | null
  }
}

type AdminContextValue = {
  session: AdminSessionInfo | null
  status: "loading" | "ready"
  refresh: () => Promise<void>
  signOut: () => Promise<void>
  needsSetup: boolean
  needsStepUp: boolean
}

const AdminContext = createContext<AdminContextValue | null>(null)

export const AdminProvider = ({ children }: { children: React.ReactNode }) => {
  const [session, setSession] = useState<AdminSessionInfo | null>(null)
  const [status, setStatus] = useState<"loading" | "ready">("loading")

  const refresh = useCallback(async () => {
    setStatus("loading")
    const data = await apiRequest<AdminSessionInfo>("/admin/me", { method: "GET" })
    if (data.ok) {
      setSession({
        user: data.user,
        setup: data.setup,
        session: data.session,
      })
    } else {
      setSession(null)
    }
    setStatus("ready")
  }, [])

  const signOut = useCallback(async () => {
    await apiRequest("/admin/auth/logout", { method: "POST" })
    setSession(null)
  }, [])

  const needsSetup = Boolean(session && (!session.setup.passwordSet || !session.setup.totpEnabled))

  const needsStepUp = useMemo(() => {
    if (!session?.session.stepUpAt) return true
    const stepUpAt = new Date(session.session.stepUpAt).getTime()
    if (Number.isNaN(stepUpAt)) return true
    return Date.now() - stepUpAt > 1000 * 60 * 15
  }, [session])

  const value = useMemo<AdminContextValue>(
    () => ({
      session,
      status,
      refresh,
      signOut,
      needsSetup,
      needsStepUp,
    }),
    [session, status, refresh, signOut, needsSetup, needsStepUp],
  )

  return <AdminContext.Provider value={value}>{children}</AdminContext.Provider>
}

export const useAdmin = () => {
  const context = useContext(AdminContext)
  if (!context) {
    throw new Error("useAdmin must be used within AdminProvider")
  }
  return context
}
