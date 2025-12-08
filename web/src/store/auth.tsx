import { create, ExtractState } from "zustand"
import { persist, createJSONStorage } from "zustand/middleware"

type AuthState = {
  token: null | string
  currentUserId: null | number

  saveAuthentication: (token: string, userId: number) => void
  clearAuthentication: () => void
}

export const useAuthStore = create(
  persist<AuthState>(
    (set) => ({
      token: null as null | string,
      currentUserId: null as null | number,

      // Actions
      saveAuthentication: (token: string, userId: number) => set(() => ({ token, userId })),
      clearAuthentication: () => set(() => ({ token: null, currentUserId: null })),
    }),
    {
      name: "auth-store",
      storage: createJSONStorage(() => localStorage),
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
