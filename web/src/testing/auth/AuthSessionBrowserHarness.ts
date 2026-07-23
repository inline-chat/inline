import {
  AuthStore,
  BrowserAuthSessionPersistence,
} from "@inline/client/core"
import { userId } from "@inline/ids"

const waitFor = async (
  predicate: () => boolean,
  timeoutMs = 2_000,
) => {
  const deadline = performance.now() + timeoutMs
  while (!predicate()) {
    if (performance.now() >= deadline) {
      throw new Error("Timed out waiting for browser auth convergence")
    }
    await new Promise<void>((resolve) => setTimeout(resolve, 10))
  }
}

export const runAuthSessionBrowserHarness = async () => {
  const key = `inline-auth-browser-smoke-${crypto.randomUUID()}`
  const tokenKey = `${key}:token`
  const userIdKey = `${key}:user-id`
  const token = "synthetic-browser-smoke-token"
  localStorage.setItem(tokenKey, token)
  localStorage.setItem(userIdKey, "9007199254740993")

  const first = new AuthStore({
    storage: new BrowserAuthSessionPersistence(key),
  })
  await first.ready
  if (
    first.getToken() !== token ||
    first.getState().currentUserId !==
      userId("9007199254740993")
  ) {
    throw new Error("Legacy browser auth migration lost session identity")
  }
  if (
    localStorage.getItem(tokenKey) != null ||
    localStorage.getItem(userIdKey) != null
  ) {
    throw new Error("Legacy browser credential material was not removed")
  }

  const second = new AuthStore({
    storage: new BrowserAuthSessionPersistence(key),
  })
  await second.ready
  if (second.getToken() !== token) {
    throw new Error("IndexedDB browser session did not survive reload")
  }

  await first.logout()
  await waitFor(() => !second.isLoggedIn())
  const afterLogout = new AuthStore({
    storage: new BrowserAuthSessionPersistence(key),
  })
  await afterLogout.ready
  if (afterLogout.isLoggedIn()) {
    throw new Error("Logged-out browser session was resurrected")
  }

  first.dispose()
  second.dispose()
  afterLogout.dispose()

  return {
    migratedUserId: "9007199254740993",
    legacyCredentialKeysRemoved: true,
    siblingSessionCleared: true,
    restartStayedLoggedOut: true,
  }
}
