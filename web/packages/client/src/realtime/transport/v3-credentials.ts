import type { InlineProtocolAuthorization } from "@inline-chat/protocol/secure/connection"

/**
 * V3 authority for one account.
 *
 * - `staged`: a permanent key was created and stored before the request that
 *   binds it (`authUpgradeSession`), so a retry after a lost reply proves
 *   possession of the same key instead of minting another. Not usable yet.
 * - `bound`: the server bound the permanent key to this account session; the
 *   transport may derive temporary keys from it.
 */
export type InlineProtocolCredentials = {
  /** The account's user ID, as the decimal string the rest of the core uses. */
  userId: string
  accountSessionId?: string
  state: "staged" | "bound"
  permanent: InlineProtocolAuthorization
  /** Optional cache of the last verified temporary key; saves a handshake on reconnect. */
  temporary?: InlineProtocolAuthorization
}

/**
 * Where the permanent key lives. Keyed by account (user ID). Implementations
 * must keep accounts apart, return copies, and make `erase` final: sign-out and
 * server revocation call it, and nothing may resurrect the key afterwards.
 */
export interface InlineProtocolKeyStore {
  get(accountId: string): Promise<InlineProtocolCredentials | undefined>
  set(accountId: string, credentials: InlineProtocolCredentials): Promise<void>
  erase(accountId: string): Promise<void>
}

const cloneAuthorization = (value: InlineProtocolAuthorization): InlineProtocolAuthorization => ({
  ...value,
  key: value.key.slice(),
  keyId: value.keyId.slice(),
})

export const cloneInlineProtocolCredentials = (value: InlineProtocolCredentials): InlineProtocolCredentials => ({
  ...value,
  permanent: cloneAuthorization(value.permanent),
  ...(value.temporary ? { temporary: cloneAuthorization(value.temporary) } : {}),
})

const wipe = (value: InlineProtocolCredentials) => {
  value.permanent.key.fill(0)
  value.temporary?.key.fill(0)
}

/** In-memory store: per tab or worker, gone on reload. Wipes key bytes on erase and replace. */
export class MemoryInlineProtocolKeyStore implements InlineProtocolKeyStore {
  readonly #values = new Map<string, InlineProtocolCredentials>()

  async get(accountId: string): Promise<InlineProtocolCredentials | undefined> {
    const value = this.#values.get(accountId)
    return value ? cloneInlineProtocolCredentials(value) : undefined
  }

  async set(accountId: string, credentials: InlineProtocolCredentials): Promise<void> {
    const previous = this.#values.get(accountId)
    this.#values.set(accountId, cloneInlineProtocolCredentials(credentials))
    if (previous) wipe(previous)
  }

  async erase(accountId: string): Promise<void> {
    const previous = this.#values.get(accountId)
    this.#values.delete(accountId)
    if (previous) wipe(previous)
  }

  get size(): number {
    return this.#values.size
  }
}
