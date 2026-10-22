import { describe, expect, test } from "bun:test"
import { TemporaryAuthorizationKeyStore } from "./temporaryKeys"

describe("Inline Protocol temporary authorization keys", () => {
  test("binds idempotently, rejects conflicts, cascades revocation, and expires in memory", async () => {
    let now = 100
    const store = new TemporaryAuthorizationKeyStore(() => now, 2)
    const keyId = new Uint8Array(8).fill(1)
    expect(await store.create({
      key: new Uint8Array(256).fill(2), keyId, temporary: true, expiresAt: 200, serverSalt: 3n,
    })).toBe("created")
    const binding = {
      permanentAuthKeyId: new Uint8Array(8).fill(4), temporarySessionId: 5n, nonce: 6n, expiresAt: 190,
      userId: 7, accountSessionId: 8,
    }
    expect(store.bind(keyId, binding)).toBe("created")
    expect(store.bind(keyId, binding)).toBe("idempotent")
    expect(store.bind(keyId, { ...binding, nonce: 7n })).toBe("conflict")
    expect(store.revokePermanent(binding.permanentAuthKeyId)).toBe(1)
    expect(store.get(keyId)).toBeUndefined()
    await store.create({
      key: new Uint8Array(256).fill(8), keyId, temporary: true, expiresAt: 110, serverSalt: 9n,
    })
    now = 111
    expect(store.size).toBe(0)
  })

  test("an expired entry is invisible to lookups before any sweep runs", async () => {
    let now = 100
    const store = new TemporaryAuthorizationKeyStore(() => now, 10)
    const keyId = new Uint8Array(8).fill(3)
    await store.create({ key: new Uint8Array(256).fill(1), keyId, temporary: true, expiresAt: 150, serverSalt: 1n })
    const sweeps = store.sweepCount
    expect(store.get(keyId)).toBeDefined()
    now = 150
    expect(store.get(keyId)).toBeUndefined()
    expect(store.rotateServerSalt(keyId, 2n)).toBeFalse()
    expect(store.sweepCount).toBe(sweeps)
    store.clear()
  })

  test("a binding that expires before its key governs lookups", async () => {
    let now = 100
    const store = new TemporaryAuthorizationKeyStore(() => now, 10)
    const keyId = new Uint8Array(8).fill(4)
    await store.create({ key: new Uint8Array(256).fill(1), keyId, temporary: true, expiresAt: 500, serverSalt: 1n })
    store.bind(keyId, {
      permanentAuthKeyId: new Uint8Array(8).fill(5), temporarySessionId: 1n, nonce: 2n, expiresAt: 200,
      userId: 1, accountSessionId: 2,
    })
    now = 199
    expect(store.get(keyId)).toBeDefined()
    now = 200
    expect(store.get(keyId)).toBeUndefined()
    store.clear()
  })

  test("lookups stay O(1) with fifty thousand live entries", async () => {
    const now = 100
    const store = new TemporaryAuthorizationKeyStore(() => now, 60_000)
    const id = (index: number) => {
      const bytes = new Uint8Array(8)
      new DataView(bytes.buffer).setUint32(0, index, true)
      return bytes
    }
    const key = new Uint8Array(256).fill(9)
    for (let index = 0; index < 50_000; index += 1) {
      await store.create({ key, keyId: id(index), temporary: true, expiresAt: 1_000, serverSalt: 1n })
    }
    const sweeps = store.sweepCount
    for (let index = 0; index < 50_000; index += 997) expect(store.get(id(index))).toBeDefined()
    expect(store.sweepCount).toBe(sweeps)
    store.clear()
  })

  test("sweeps expired entries only when full or on its timer", async () => {
    let now = 100
    const store = new TemporaryAuthorizationKeyStore(() => now, 2, 10)
    const key = new Uint8Array(256).fill(1)
    await store.create({ key, keyId: new Uint8Array(8).fill(1), temporary: true, expiresAt: 110, serverSalt: 1n })
    await store.create({ key, keyId: new Uint8Array(8).fill(2), temporary: true, expiresAt: 110, serverSalt: 1n })
    expect(store.sweepCount).toBe(0)
    now = 120
    expect(await store.create({
      key, keyId: new Uint8Array(8).fill(3), temporary: true, expiresAt: 200, serverSalt: 1n,
    })).toBe("created")
    expect(store.sweepCount).toBe(1)
    await Bun.sleep(25)
    expect(store.sweepCount).toBeGreaterThan(1)
    store.clear()
    const afterClear = store.sweepCount
    await Bun.sleep(25)
    expect(store.sweepCount).toBe(afterClear)
  })
})
