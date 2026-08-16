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
})
