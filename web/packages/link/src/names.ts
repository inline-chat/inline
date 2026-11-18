/**
 * Lock and channel names for an account. A module of its own, with no
 * imports, so code that only needs the names (the app's storage sweep, which
 * asks whether an account's leader lock is held) does not pull in the link.
 */

/** Bumped when the messages between tabs change shape. */
export const CHANNEL_WIRE = 1

export type AccountKey = {
  /** The API server origin, for example `https://api.inline.chat`. */
  origin: string
  userId: string
}

export type LockNames = {
  leader: string
  term(term: string): string
  context(contextId: string): string
}

/** Lock and channel names for an account, keyed by server origin and user ID. */
export const linkNames = (account: AccountKey) => {
  const base = `inline-link/v${CHANNEL_WIRE}/${encodeURIComponent(account.origin)}/${encodeURIComponent(account.userId)}`
  const locks: LockNames = {
    leader: `${base}/leader`,
    term: (term) => `${base}/term/${term}`,
    context: (contextId) => `${base}/context/${contextId}`,
  }
  return { channel: base, locks }
}
