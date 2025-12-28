import { createContext, type ReactNode, useContext, useEffect, useMemo, useRef, useSyncExternalStore } from "react"
import {
  useAuthActions as useAuthActionsBase,
  useAuthState as useAuthStateBase,
  useCurrentUserId as useCurrentUserIdBase,
  useHasHydrated as useHasHydratedBase,
  useIsLoggedIn as useIsLoggedInBase,
  useToken as useTokenBase,
} from "@inline/auth"
import { auth as defaultAuth, type AuthState, type AuthStore } from "../auth"
import { db as defaultDb, type Db } from "../database"
import { RealtimeClient, type RealtimeConnectionState } from "../realtime"

export type InlineClientContextValue = {
  realtime: RealtimeClient
  db: Db
  auth: AuthStore
}

const InlineClientContext = createContext<InlineClientContextValue | null>(null)

let defaultClient: InlineClientContextValue | null = null

const getDefaultClient = () => {
  if (!defaultClient) {
    const auth = defaultAuth
    const db = defaultDb
    const realtime = new RealtimeClient({ auth, db })
    defaultClient = { auth, db, realtime }
  }
  return defaultClient
}

export type InlineClientProviderProps = {
  children: ReactNode
  value?: InlineClientContextValue
  realtime?: RealtimeClient
  db?: Db
  auth?: AuthStore
  autoConnect?: boolean
}

export function InlineClientProvider({
  children,
  value,
  realtime,
  db,
  auth,
  autoConnect = true,
}: InlineClientProviderProps) {
  const resolved = useMemo<InlineClientContextValue>(() => {
    if (value) return value
    const resolvedAuth = auth ?? defaultAuth
    const resolvedDb = db ?? defaultDb
    const resolvedRealtime = realtime ?? new RealtimeClient({ auth: resolvedAuth, db: resolvedDb })
    return { auth: resolvedAuth, db: resolvedDb, realtime: resolvedRealtime }
  }, [value, auth, db, realtime])

  const reconnectRef = useRef(resolved)
  reconnectRef.current = resolved

  useEffect(() => {
    if (!autoConnect) return

    const syncConnection = () => {
      const next = reconnectRef.current
      if (next.auth.isLoggedIn()) {
        void next.realtime.start()
      } else {
        void next.realtime.stop()
      }
    }

    syncConnection()
    const unsubscribe = resolved.auth.subscribe(syncConnection)
    return unsubscribe
  }, [resolved, autoConnect])

  return <InlineClientContext.Provider value={resolved}>{children}</InlineClientContext.Provider>
}

export function useInlineClient(): InlineClientContextValue {
  return useContext(InlineClientContext) ?? getDefaultClient()
}

export function useRealtimeClient(): RealtimeClient {
  return useInlineClient().realtime
}

export function useClientDb(): Db {
  return useInlineClient().db
}

export function useAuthStore(): AuthStore {
  return useInlineClient().auth
}

export function useAuthState(): AuthState {
  const auth = useAuthStore()
  return useAuthStateBase(auth)
}

export function useIsLoggedIn(): boolean {
  const auth = useAuthStore()
  return useIsLoggedInBase(auth)
}

export function useToken(): string | null {
  const auth = useAuthStore()
  return useTokenBase(auth)
}

export function useCurrentUserId(): number | null {
  const auth = useAuthStore()
  return useCurrentUserIdBase(auth)
}

export function useHasHydrated(): boolean {
  const auth = useAuthStore()
  return useHasHydratedBase(auth)
}

export function useAuthActions() {
  const auth = useAuthStore()
  return useAuthActionsBase(auth)
}

export function useConnectionState(): RealtimeConnectionState {
  const realtime = useRealtimeClient()
  return useSyncExternalStore(
    (listener) => realtime.onConnectionState(() => listener()),
    () => realtime.connectionState,
    () => realtime.connectionState,
  )
}
