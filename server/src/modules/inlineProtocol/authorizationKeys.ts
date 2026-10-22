import type {
  EstablishedAuthorizationKey,
  LoadedServerAuthorizationKey,
  ServerAuthorizationKeyRepository,
} from "@inline-chat/protocol/server"
import { bytesToHex } from "@inline-chat/protocol/secure"
import type { PermanentAuthorizationKey, PermanentAuthorizationKeyRepository } from "@in/server/db/models/inlineProtocol"
import { TemporaryAuthorizationKeyStore } from "./temporaryKeys"

/**
 * A bound temporary key re-verifies its permanent authority at most this often.
 * Local revocations invalidate immediately; this bounds cross-process lag only.
 */
export const AUTHORITY_CACHE_TTL_MS = 30_000
const NEGATIVE_AUTHORITY_CACHE_TTL_MS = 5_000
const MAX_AUTHORITY_CACHE_ENTRIES = 10_000

/** Only the identity a binding is checked against; the permanent key bytes are never retained. */
type PermanentAuthority = {
  userId?: number
  accountSessionId?: number
  /** Unix seconds. */
  expiresAt?: number
}

type AuthorityCacheEntry = {
  value: PermanentAuthority | undefined
  verifiedAt: number
  generation: number
}

export type InlineProtocolAuthorizationKeysOptions = {
  /** Monotonic milliseconds. */
  nowMilliseconds?: () => number
  nowSeconds?: () => number
}

type PermanentRepository = Pick<
  PermanentAuthorizationKeyRepository,
  "create" | "getActive" | "loadRevokedForBinding" | "revoke" | "rotateServerSalt"
>

export class InlineProtocolAuthorizationKeys implements ServerAuthorizationKeyRepository {
  readonly #authorities = new Map<string, AuthorityCacheEntry>()
  readonly #nowMilliseconds: () => number
  readonly #nowSeconds: () => number
  /** Bumped by every invalidation, so a lookup that raced one never repopulates the cache. */
  #generation = 0

  constructor(
    private readonly permanent: PermanentRepository,
    private readonly temporary: TemporaryAuthorizationKeyStore,
    options: InlineProtocolAuthorizationKeysOptions = {},
  ) {
    this.#nowMilliseconds = options.nowMilliseconds ?? (() => performance.now())
    this.#nowSeconds = options.nowSeconds ?? (() => Math.floor(Date.now() / 1_000))
  }

  create(key: EstablishedAuthorizationKey): Promise<"created" | "collision"> {
    return key.temporary ? this.temporary.create(key) : this.permanent.create(key)
  }

  async load(authKeyId: Uint8Array): Promise<LoadedServerAuthorizationKey | undefined> {
    const temporary = this.temporary.get(authKeyId)
    if (temporary) {
      if (temporary.binding) {
        const permanent = await this.#permanentAuthority(temporary.binding.permanentAuthKeyId)
        if (!permanent || permanent.userId !== temporary.binding.userId ||
            permanent.accountSessionId !== temporary.binding.accountSessionId) {
          temporary.key.fill(0)
          this.temporary.revoke(authKeyId)
          return undefined
        }
      }
      return {
        key: temporary.key,
        keyId: temporary.keyId,
        temporary: true,
        expiresAt: temporary.expiresAt,
        currentServerSalt: temporary.serverSalt,
        binding: temporary.binding ? {
          permanentAuthKeyId: temporary.binding.permanentAuthKeyId,
          temporarySessionId: temporary.binding.temporarySessionId,
          nonce: temporary.binding.nonce,
          expiresAt: temporary.binding.expiresAt,
          userId: temporary.binding.userId,
          accountSessionId: temporary.binding.accountSessionId,
        } : undefined,
      }
    }
    const permanent = await this.permanent.getActive(authKeyId)
    if (!permanent) return undefined
    return {
      key: permanent.key,
      keyId: permanent.keyId,
      temporary: false,
      currentServerSalt: permanent.currentServerSalt,
      previousServerSalt: permanent.previousServerSalt,
      authorized: permanent.userId !== undefined && permanent.accountSessionId !== undefined
        ? { userId: permanent.userId, accountSessionId: permanent.accountSessionId }
        : undefined,
    }
  }

  loadRevokedForBinding(authKeyId: Uint8Array): Promise<Uint8Array | undefined> {
    return this.permanent.loadRevokedForBinding(authKeyId)
  }

  async bindTemporary(input: {
    temporaryAuthKeyId: Uint8Array
    permanentAuthKeyId: Uint8Array
    temporarySessionId: bigint
    nonce: bigint
    expiresAt: number
    userId: number
    accountSessionId: number
  }): Promise<"created" | "idempotent" | "conflict"> {
    return this.temporary.bind(input.temporaryAuthKeyId, {
      permanentAuthKeyId: input.permanentAuthKeyId,
      temporarySessionId: input.temporarySessionId,
      nonce: input.nonce,
      expiresAt: input.expiresAt,
      userId: input.userId,
      accountSessionId: input.accountSessionId,
    })
  }

  async revokePermanent(authKeyId: Uint8Array): Promise<boolean> {
    this.invalidatePermanent(authKeyId)
    const revoked = await this.permanent.revoke(authKeyId)
    if (revoked) this.temporary.revokePermanent(authKeyId)
    return revoked
  }

  async rotateServerSalt(authKeyId: Uint8Array, newServerSalt: bigint): Promise<boolean> {
    return this.temporary.rotateServerSalt(authKeyId, newServerSalt) ||
      this.permanent.rotateServerSalt(authKeyId, newServerSalt)
  }

  async revoke(authKeyId: Uint8Array): Promise<boolean> {
    if (this.temporary.revoke(authKeyId)) return true
    return this.revokePermanent(authKeyId)
  }

  /** Forces the next bound-key load for this permanent key to re-read Postgres. */
  invalidatePermanent(permanentAuthKeyId: Uint8Array): void {
    this.#generation += 1
    this.#authorities.delete(bytesToHex(permanentAuthKeyId))
  }

  /** Called for local and reconciled session revocations, including logout. */
  invalidateAccountSession(userId: number, accountSessionId: number): void {
    this.#generation += 1
    for (const [id, entry] of this.#authorities) {
      if (entry.value?.userId === userId && entry.value.accountSessionId === accountSessionId) {
        this.#authorities.delete(id)
      }
    }
  }

  get cachedAuthorityCount(): number {
    return this.#authorities.size
  }

  clearTemporary(): void {
    this.temporary.clear()
    this.#authorities.clear()
  }

  async #permanentAuthority(permanentAuthKeyId: Uint8Array): Promise<PermanentAuthority | undefined> {
    const id = bytesToHex(permanentAuthKeyId)
    const now = this.#nowMilliseconds()
    const cached = this.#authorities.get(id)
    if (cached) {
      const ttl = cached.value ? AUTHORITY_CACHE_TTL_MS : NEGATIVE_AUTHORITY_CACHE_TTL_MS
      const expired = cached.value?.expiresAt !== undefined && cached.value.expiresAt <= this.#nowSeconds()
      if (now - cached.verifiedAt < ttl && !expired) {
        // Refresh recency for LRU eviction.
        this.#authorities.delete(id)
        this.#authorities.set(id, cached)
        return cached.value
      }
      this.#authorities.delete(id)
    }
    const generation = this.#generation
    const loaded = await this.permanent.getActive(permanentAuthKeyId)
    const value = loaded ? this.#authorityFrom(loaded) : undefined
    if (generation === this.#generation) {
      this.#authorities.set(id, { value, verifiedAt: this.#nowMilliseconds(), generation })
      while (this.#authorities.size > MAX_AUTHORITY_CACHE_ENTRIES) {
        const oldest = this.#authorities.keys().next().value
        if (oldest === undefined) break
        this.#authorities.delete(oldest)
      }
    }
    return value
  }

  #authorityFrom(loaded: PermanentAuthorizationKey): PermanentAuthority {
    // Bound-key checks need only identity and expiry. Wipe the unwrapped key at once
    // rather than retaining permanent key material in a long-lived cache.
    loaded.key.fill(0)
    return {
      userId: loaded.userId,
      accountSessionId: loaded.accountSessionId,
      expiresAt: loaded.expiresAt === undefined ? undefined : Math.floor(loaded.expiresAt.getTime() / 1_000),
    }
  }
}
