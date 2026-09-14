import { createContext, type ReactNode, useContext } from "react"
import type { AuthStore } from "../auth"
import type { InlineClientContextValue } from "../client"
import type { Db } from "../database"
import type { RealtimeService } from "../realtime"

const InlineClientContext =
  createContext<InlineClientContextValue | null>(null)

export function InlineClientProvider({
  children,
  value,
}: {
  children: ReactNode
  value: InlineClientContextValue
}) {
  return (
    <InlineClientContext.Provider value={value}>
      {children}
    </InlineClientContext.Provider>
  )
}

export function useInlineClient(): InlineClientContextValue {
  const client = useContext(InlineClientContext)
  if (!client) {
    throw new Error(
      "useInlineClient must be used within InlineClientProvider",
    )
  }
  return client
}

export function useRealtimeClient(): RealtimeService {
  return useInlineClient().realtime
}

export function useClientDb(): Db {
  return useInlineClient().db
}

export function useAuthStore(): AuthStore {
  return useInlineClient().auth
}
