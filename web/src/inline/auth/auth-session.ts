import { useSyncExternalStore } from "react"
import {
  getAuthSessionSnapshot,
  subscribeAuthSession,
} from "./auth-session-core"

export { authSession } from "./auth-session-core"

export function useAuthSession() {
  return useSyncExternalStore(
    subscribeAuthSession,
    getAuthSessionSnapshot,
    getAuthSessionSnapshot,
  )
}
