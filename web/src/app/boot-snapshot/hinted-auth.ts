/**
 * The auth store as the app model sees it at a start with a boot snapshot:
 * until the real store has read its storage (IndexedDB, asynchronous), it
 * reports the snapshot's user as signed in, so the gate renders the shell in
 * the first frame. From the real store's first answer on, it is the real
 * store, and the app model follows it: a different user or none tears the
 * provisional session down at once.
 *
 * The token reported meanwhile is `PENDING_TOKEN`, a stand-in. The session
 * started with it is connected through a `DeferredEndpoint`, which replaces
 * it with the confirmed token or drops it.
 */

import type { UserID } from "@inline/ids"
import type { AuthStateLike, AuthStoreLike } from "@inline/view/features"

/** Not a credential: marks a session started from the snapshot's hint. */
export const PENDING_TOKEN = "boot-snapshot:pending"

export const hintedAuthStore = (store: AuthStoreLike, userId: UserID): AuthStoreLike => {
  const getState = (): AuthStateLike => {
    const state = store.getState()
    if (state.hasHydrated) return state
    return { token: PENDING_TOKEN, currentUserId: userId, hasHydrated: true }
  }
  return {
    getState,
    subscribe: (listener) => store.subscribe(() => listener(getState())),
    logout: () => store.logout(),
  }
}
