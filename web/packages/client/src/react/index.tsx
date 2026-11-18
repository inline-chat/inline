import { useEffect, useRef, useState, useSyncExternalStore } from "react"
import {
  useAuthActions as useAuthActionsBase,
  useAuthState as useAuthStateBase,
  useCurrentUserId as useCurrentUserIdBase,
  useHasHydrated as useHasHydratedBase,
  useIsLoggedIn as useIsLoggedInBase,
  useToken as useTokenBase,
} from "@inline/auth/react"
import type { UserID } from "@inline/ids"
import type { AuthState } from "../auth"
import type { InlineClientContextValue } from "../client"
import type { Db } from "../database"
import type { RealtimeConnectionState } from "../realtime"
import { useAuthStore, useClientDb, useRealtimeClient } from "./InlineClientContext"

export type { InlineClientContextValue } from "../client"
export {
  InlineClientProvider,
  useAuthStore,
  useClientDb,
  useInlineClient,
  useRealtimeClient,
} from "./InlineClientContext"

export type InlineClientProviderOptions = {
  value: InlineClientContextValue
  autoConnect?: boolean
}

export type InlineClientProviderState = {
  value: InlineClientContextValue
  hasDbHydrated: boolean
}

export function useInlineClientProvider({
  value,
  autoConnect = true,
}: InlineClientProviderOptions): InlineClientProviderState {
  const reconnectRef = useRef(value)
  reconnectRef.current = value

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
    const unsubscribe = value.auth.subscribe(syncConnection)
    return unsubscribe
  }, [value, autoConnect])

  const hasDbHydrated = useDbHasHydrated(value.db)

  return { value, hasDbHydrated }
}

export function useDbHasHydrated(db?: Db): boolean {
  const resolvedDb = db ?? useClientDb()
  const reactLog = resolvedDb.logger.withScope("React")
  const [hydrated, setHydrated] = useState(resolvedDb.hasHydrated)

  useEffect(() => {
    let active = true
    if (resolvedDb.hasHydrated) {
      if (resolvedDb.hydrationState === "pending") {
        reactLog.error("storage.hydration.invalid_state", {
          hydrationState: resolvedDb.hydrationState,
        })
      }
      if (resolvedDb.hydrationState === "failed") {
        reactLog.error("storage.hydration.failed", {
          hydrationState: resolvedDb.hydrationState,
        })
      }
      reactLog.debug("storage.hydration.already_ready")
      setHydrated(true)
      return () => {
        active = false
      }
    }

    void resolvedDb.ready.then(() => {
      if (resolvedDb.hydrationState === "failed") {
        reactLog.error("storage.hydration.failed", {
          hydrationState: resolvedDb.hydrationState,
        })
      }
      reactLog.debug("storage.hydration.ready")
      if (active) setHydrated(true)
    })

    return () => {
      active = false
    }
  }, [resolvedDb])

  return hydrated
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

export function useCurrentUserId(): UserID | null {
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
