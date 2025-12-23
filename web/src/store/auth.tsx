import { create } from "zustand"
import { persist, createJSONStorage } from "zustand/middleware"

type AuthState = {
  token: null | string
  currentUserId: null | number
  hasHydrated: boolean

  saveAuthentication: (token: string, userId: number) => void
  clearAuthentication: () => void
  setHasHydrated: (value: boolean) => void
}

export const useAuthStore = create(
  persist<AuthState>(
    (set) => ({
      token: null as null | string,
      currentUserId: null as null | number,
      hasHydrated: false,

      // Actions
      saveAuthentication: (token: string, userId: number) =>
        set(() => ({ token, currentUserId: userId })),
      clearAuthentication: () => set(() => ({ token: null, currentUserId: null })),
      setHasHydrated: (value: boolean) => set(() => ({ hasHydrated: value })),
    }),
    {
      name: "auth-store",
      storage: createJSONStorage(() => localStorage),
      version: 1,
      migrate: (persistedState) => {
        if (!persistedState || typeof persistedState !== "object") {
          return persistedState as AuthState
        }
        const state = persistedState as AuthState & { userId?: number | null }
        return {
          ...state,
          currentUserId: state.currentUserId ?? state.userId ?? null,
          hasHydrated: false,
        }
      },
      onRehydrateStorage: () => (state) => {
        state?.setHasHydrated(true)
      },
    },
  ),
)

export const useIsLoggedIn = () => {
  const token = useAuthStore((state: AuthState) => state.token)
  const currentUserId = useAuthStore((state: AuthState) => state.currentUserId)

  return token != null && currentUserId != null
}

export const useToken = () => {
  return useAuthStore((state: AuthState) => state.token)
}

export const useCurrentUserId = () => {
  return useAuthStore((state: AuthState) => state.currentUserId)
}

export const useHasHydrated = () => {
  return useAuthStore((state: AuthState) => state.hasHydrated)
}
