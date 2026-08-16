import { bytesToHex, equalBytes, type EstablishedAuthorizationKey } from "@inline-chat/protocol/secure"
import { InlineProtocolKeyStoreError } from "./errors"

export type TemporaryKeyBinding = {
  permanentAuthKeyId: Uint8Array
  temporarySessionId: bigint
  nonce: bigint
  expiresAt: number
  userId: number
  accountSessionId: number
}

type TemporaryKeyEntry = {
  key: Uint8Array
  keyId: Uint8Array
  serverSalt: bigint
  expiresAt: number
  binding?: TemporaryKeyBinding
}

export class TemporaryAuthorizationKeyStore {
  readonly #entries = new Map<string, TemporaryKeyEntry>()

  constructor(
    private readonly nowSeconds: () => number,
    private readonly capacity = 100_000,
  ) {
    if (!Number.isSafeInteger(capacity) || capacity < 1) throw new RangeError("Invalid temporary-key capacity")
  }

  async create(key: EstablishedAuthorizationKey): Promise<"created" | "collision"> {
    if (!key.temporary || key.expiresAt === undefined || key.key.length !== 256 || key.keyId.length !== 8) {
      throw new InlineProtocolKeyStoreError({ operation: "create_temporary_shape" })
    }
    this.#pruneExpired()
    const id = bytesToHex(key.keyId)
    if (this.#entries.has(id)) return "collision"
    if (this.#entries.size >= this.capacity) throw new InlineProtocolKeyStoreError({ operation: "temporary_capacity" })
    this.#entries.set(id, {
      key: key.key.slice(),
      keyId: key.keyId.slice(),
      serverSalt: key.serverSalt,
      expiresAt: key.expiresAt,
    })
    return "created"
  }

  get(authKeyId: Uint8Array): Omit<TemporaryKeyEntry, "binding"> & { binding?: TemporaryKeyBinding } | undefined {
    this.#pruneExpired()
    const entry = this.#entries.get(bytesToHex(authKeyId))
    return entry ? this.#copy(entry) : undefined
  }

  bind(authKeyId: Uint8Array, binding: TemporaryKeyBinding): "created" | "idempotent" | "conflict" {
    this.#pruneExpired()
    const entry = this.#entries.get(bytesToHex(authKeyId))
    if (!entry || binding.expiresAt > entry.expiresAt + 30 || binding.expiresAt <= this.nowSeconds()) {
      throw new InlineProtocolKeyStoreError({ operation: "bind_temporary_missing_or_expired" })
    }
    if (!entry.binding) {
      entry.binding = this.#copyBinding(binding)
      return "created"
    }
    const existing = entry.binding
    return equalBytes(existing.permanentAuthKeyId, binding.permanentAuthKeyId) &&
      existing.temporarySessionId === binding.temporarySessionId &&
      existing.nonce === binding.nonce &&
      existing.expiresAt === binding.expiresAt
      ? "idempotent"
      : "conflict"
  }

  revokePermanent(permanentAuthKeyId: Uint8Array): number {
    let revoked = 0
    for (const [id, entry] of this.#entries) {
      if (entry.binding && equalBytes(entry.binding.permanentAuthKeyId, permanentAuthKeyId)) {
        entry.key.fill(0)
        this.#entries.delete(id)
        revoked += 1
      }
    }
    return revoked
  }

  rotateServerSalt(authKeyId: Uint8Array, serverSalt: bigint): boolean {
    this.#pruneExpired()
    const entry = this.#entries.get(bytesToHex(authKeyId))
    if (!entry) return false
    entry.serverSalt = serverSalt
    return true
  }

  revoke(authKeyId: Uint8Array): boolean {
    const id = bytesToHex(authKeyId)
    const entry = this.#entries.get(id)
    if (!entry) return false
    entry.key.fill(0)
    this.#entries.delete(id)
    return true
  }

  clear(): void {
    for (const entry of this.#entries.values()) entry.key.fill(0)
    this.#entries.clear()
  }

  get size(): number {
    this.#pruneExpired()
    return this.#entries.size
  }

  #pruneExpired(): void {
    const now = this.nowSeconds()
    for (const [id, entry] of this.#entries) {
      const effectiveExpiry = Math.min(entry.expiresAt, entry.binding?.expiresAt ?? entry.expiresAt)
      if (effectiveExpiry <= now) {
        entry.key.fill(0)
        this.#entries.delete(id)
      }
    }
  }

  #copy(entry: TemporaryKeyEntry): TemporaryKeyEntry {
    return {
      ...entry,
      key: entry.key.slice(),
      keyId: entry.keyId.slice(),
      binding: entry.binding ? this.#copyBinding(entry.binding) : undefined,
    }
  }

  #copyBinding(binding: TemporaryKeyBinding): TemporaryKeyBinding {
    return { ...binding, permanentAuthKeyId: binding.permanentAuthKeyId.slice() }
  }
}
