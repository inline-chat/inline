import { useSyncExternalStore } from "react"
import type { AuthSession, AuthState, AuthStore } from "./core"

export function useAuthState(auth: AuthStore): AuthState {
  return useSyncExternalStore(
    (listener) => auth.subscribe(() => listener()),
    () => auth.getSnapshot(),
    () => auth.getSnapshot(),
  )
}

export function useIsLoggedIn(auth: AuthStore): boolean {
  return useSyncExternalStore(
    (listener) => auth.subscribe(() => listener()),
    () => auth.isLoggedIn(),
    () => auth.isLoggedIn(),
  )
}

export function useToken(auth: AuthStore): string | null {
  const state = useAuthState(auth)
  return state.token
}

export function useCurrentUserId(auth: AuthStore): number | null {
  const state = useAuthState(auth)
  return state.currentUserId
}

export function useHasHydrated(auth: AuthStore): boolean {
  const state = useAuthState(auth)
  return state.hasHydrated
}

export function useAuthActions(auth: AuthStore) {
  return {
    login: (session: AuthSession) => auth.login(session),
    logout: () => auth.logout(),
  }
}
