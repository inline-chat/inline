import {
  AuthStore,
  BrowserAuthSessionPersistence,
  type AuthState,
} from "@inline/client/auth"
import { InlineDesktopAuthSessionPersistence } from "./InlineDesktopAuthSessionPersistence"

const desktop =
  typeof window === "undefined"
    ? undefined
    : window.inlineDesktop

const authPersistence = desktop
  ? new InlineDesktopAuthSessionPersistence(desktop.auth)
  : new BrowserAuthSessionPersistence("inline-web-session")

export const authSession = new AuthStore({
  storage: authPersistence,
})

let snapshot: AuthState = authSession.getSnapshot()
const listeners = new Set<() => void>()

const updateSnapshot = () => {
  snapshot = authSession.getSnapshot()
  for (const listener of listeners) listener()
}

authSession.subscribe(() => {
  updateSnapshot()
})

export const subscribeAuthSession = (
  listener: () => void,
) => {
  listeners.add(listener)
  return () => listeners.delete(listener)
}

export const getAuthSessionSnapshot = () => snapshot
