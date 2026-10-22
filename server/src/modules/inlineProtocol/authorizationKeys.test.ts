import { describe, expect, test } from "bun:test"
import type { EstablishedAuthorizationKey } from "@inline-chat/protocol/secure"
import type { PermanentAuthorizationKey } from "@in/server/db/models/inlineProtocol"
import { AUTHORITY_CACHE_TTL_MS, InlineProtocolAuthorizationKeys } from "./authorizationKeys"
import { TemporaryAuthorizationKeyStore } from "./temporaryKeys"

const permanentKeyId = new Uint8Array(8).fill(7)
const temporaryKeyId = new Uint8Array(8).fill(3)

class CountingPermanentRepository {
  getActiveCalls = 0
  active: Omit<PermanentAuthorizationKey, "key"> | undefined = {
    keyId: permanentKeyId,
    currentServerSalt: 1n,
    userId: 11,
    accountSessionId: 22,
    createdAt: new Date(0),
  }
  lastReturnedKey: Uint8Array | undefined

  async create(_key: EstablishedAuthorizationKey): Promise<"created" | "collision"> { return "created" }
  async getActive(_authKeyId: Uint8Array): Promise<PermanentAuthorizationKey | undefined> {
    this.getActiveCalls += 1
    if (!this.active) return undefined
    this.lastReturnedKey = new Uint8Array(256).fill(0x5a)
    return { ...this.active, key: this.lastReturnedKey }
  }
  async loadRevokedForBinding(_authKeyId: Uint8Array): Promise<Uint8Array | undefined> { return undefined }
  async revoke(_authKeyId: Uint8Array): Promise<boolean> {
    this.active = undefined
    return true
  }
  async rotateServerSalt(_authKeyId: Uint8Array, _salt: bigint): Promise<boolean> { return true }
}

const fixture = async () => {
  let nowMs = 1_000
  const nowSeconds = 1_000
  const repository = new CountingPermanentRepository()
  const temporary = new TemporaryAuthorizationKeyStore(() => nowSeconds)
  const keys = new InlineProtocolAuthorizationKeys(repository, temporary, {
    nowMilliseconds: () => nowMs,
    nowSeconds: () => nowSeconds,
  })
  await temporary.create({
    key: new Uint8Array(256).fill(1), keyId: temporaryKeyId, temporary: true,
    expiresAt: nowSeconds + 3_600, serverSalt: 2n,
  })
  temporary.bind(temporaryKeyId, {
    permanentAuthKeyId: permanentKeyId, temporarySessionId: 5n, nonce: 6n, expiresAt: nowSeconds + 3_600,
    userId: 11, accountSessionId: 22,
  })
  return { keys, repository, temporary, advance: (ms: number) => { nowMs += ms } }
}

describe("Inline Protocol authorization keys", () => {
  test("a second bound-key load within the TTL performs no permanent-key query", async () => {
    const { keys, repository, temporary } = await fixture()
    expect(await keys.load(temporaryKeyId)).toBeDefined()
    expect(await keys.load(temporaryKeyId)).toBeDefined()
    expect(await keys.load(temporaryKeyId)).toBeDefined()
    expect(repository.getActiveCalls).toBe(1)
    // The cache keeps identity only; the unwrapped permanent key is wiped at once.
    expect(repository.lastReturnedKey!.every((byte) => byte === 0)).toBeTrue()
    temporary.clear()
  })

  test("invalidating the permanent key or its account session forces a reload", async () => {
    const { keys, repository, temporary } = await fixture()
    await keys.load(temporaryKeyId)
    keys.invalidatePermanent(permanentKeyId)
    await keys.load(temporaryKeyId)
    expect(repository.getActiveCalls).toBe(2)
    keys.invalidateAccountSession(11, 99)
    await keys.load(temporaryKeyId)
    expect(repository.getActiveCalls).toBe(2)
    keys.invalidateAccountSession(11, 22)
    await keys.load(temporaryKeyId)
    expect(repository.getActiveCalls).toBe(3)
    temporary.clear()
  })

  test("TTL expiry forces a reload", async () => {
    const { keys, repository, temporary, advance } = await fixture()
    await keys.load(temporaryKeyId)
    advance(AUTHORITY_CACHE_TTL_MS - 1)
    await keys.load(temporaryKeyId)
    expect(repository.getActiveCalls).toBe(1)
    advance(1)
    await keys.load(temporaryKeyId)
    expect(repository.getActiveCalls).toBe(2)
    temporary.clear()
  })

  test("a revoked permanent key fails the bound load and revokes the temporary entry", async () => {
    const { keys, repository, temporary } = await fixture()
    await keys.load(temporaryKeyId)
    repository.active = undefined
    keys.invalidatePermanent(permanentKeyId)
    expect(await keys.load(temporaryKeyId)).toBeUndefined()
    expect(temporary.get(temporaryKeyId)).toBeUndefined()
    temporary.clear()
  })

  test("revokePermanent invalidates before the revocation commits", async () => {
    const { keys, repository, temporary } = await fixture()
    await keys.load(temporaryKeyId)
    expect(await keys.revokePermanent(permanentKeyId)).toBeTrue()
    expect(temporary.get(temporaryKeyId)).toBeUndefined()
    expect(keys.cachedAuthorityCount).toBe(0)
    expect(repository.getActiveCalls).toBe(1)
    temporary.clear()
  })

  test("a lookup that races an invalidation does not repopulate the cache", async () => {
    const { keys, repository, temporary } = await fixture()
    const loading = keys.load(temporaryKeyId)
    keys.invalidateAccountSession(11, 22)
    await loading
    expect(keys.cachedAuthorityCount).toBe(0)
    await keys.load(temporaryKeyId)
    expect(repository.getActiveCalls).toBe(2)
    temporary.clear()
  })
})
