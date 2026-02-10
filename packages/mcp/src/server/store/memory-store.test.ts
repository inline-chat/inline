import { describe, expect, it } from "vitest"
import { __storeIndexLoaded, createMemoryStore } from "./index"

describe("memory store", () => {
  it("executes store index module", () => {
    expect(__storeIndexLoaded).toBe(true)
  })

  it("creates and fetches a client", () => {
    const store = createMemoryStore()
    store.ensureSchema()
    const now = 1000
    const client = store.createClient({ redirectUris: ["https://example.com/cb"], clientName: "test", nowMs: now })
    expect(store.getClient(client.clientId)).toEqual(client)
    expect(store.getClient("missing")).toBeNull()
  })

  it("auth request lifecycle + expiry", () => {
    const store = createMemoryStore()
    const now = 1000
    store.createAuthRequest({
      id: "ar1",
      clientId: "c1",
      redirectUri: "https://example.com/cb",
      state: "s",
      scope: "messages:read",
      codeChallenge: "cc",
      csrfToken: "csrf",
      deviceId: "d1",
      nowMs: now,
      expiresAtMs: now + 2,
    })
    expect(store.getAuthRequest("ar1", now)?.email).toBeNull()
    store.setAuthRequestEmail("ar1", "a@example.com")
    store.setAuthRequestInlineTokenEnc("ar1", "enc-token")
    store.setAuthRequestInlineUserId("ar1", 123n)
    expect(store.getAuthRequest("ar1", now)?.email).toBe("a@example.com")
    expect(store.getAuthRequest("ar1", now)?.inlineTokenEnc).toBe("enc-token")
    expect(store.getAuthRequest("ar1", now)?.inlineUserId).toBe(123n)
    expect(store.getAuthRequest("ar1", now + 2)).toBeNull()
    store.deleteAuthRequest("ar1")
    expect(store.getAuthRequest("ar1", now)).toBeNull()
  })

  it("grant + auth code + used marker", () => {
    const store = createMemoryStore()
    const now = 1000
    const grant = store.createGrant({
      id: "g1",
      clientId: "c1",
      inlineUserId: 42n,
      scope: "messages:read offline_access",
      spaceIds: [1n, 2n],
      inlineTokenEnc: "enc",
      nowMs: now,
    })
    expect(store.getGrant("g1")).toEqual(grant)
    expect(store.getGrant("missing")).toBeNull()

    const code = store.createAuthCode({
      code: "code1",
      grantId: "g1",
      clientId: "c1",
      redirectUri: "https://example.com/cb",
      codeChallenge: "cc",
      nowMs: now,
      expiresAtMs: now + 1,
    })
    expect(store.getAuthCode("code1", now)).toEqual(code)
    store.markAuthCodeUsed("code1", now + 123)
    expect(store.getAuthCode("code1", now)?.usedAtMs).toBe(now + 123)
    expect(store.getAuthCode("code1", now + 1)).toBeNull()
  })

  it("access/refresh token expiry and refresh revocation", () => {
    const store = createMemoryStore()

    store.createAccessToken({ tokenHashHex: "a", grantId: "g", nowMs: 1, expiresAtMs: 2 })
    expect(store.getAccessToken("a", 1)?.grantId).toBe("g")
    expect(store.getAccessToken("a", 2)).toBeNull()
    expect(store.getAccessToken("missing", 1)).toBeNull()

    // Cover "revoked" branch by injecting a token record via the public API
    // then revoking it through a second store instance isn't possible, so we
    // indirectly cover by creating a token and then mutating via as-any in test.
    ;(store as any).createAccessToken({ tokenHashHex: "rev", grantId: "g", nowMs: 1, expiresAtMs: 999 })
    ;((store as any).getAccessToken("rev", 2) as any).revokedAtMs = 2
    expect(store.getAccessToken("rev", 3)).toBeNull()

    store.createRefreshToken({ tokenHashHex: "r1", grantId: "g", nowMs: 1, expiresAtMs: 999 })
    expect(store.getRefreshToken("r1", 2)?.grantId).toBe("g")
    store.revokeRefreshToken("r1", 3, "r2")
    expect(store.getRefreshToken("r1", 4)).toBeNull()
    expect(store.getRefreshToken("missing", 1)).toBeNull()

    store.createRefreshToken({ tokenHashHex: "exp", grantId: "g", nowMs: 1, expiresAtMs: 2 })
    expect(store.getRefreshToken("exp", 2)).toBeNull()

    // revoke non-existent should be a no-op.
    store.revokeRefreshToken("missing", 1, null)
  })

  it("cleanup removes expired auth requests and auth codes", () => {
    const store = createMemoryStore()
    store.createAuthRequest({
      id: "ar1",
      clientId: "c1",
      redirectUri: "https://example.com/cb",
      state: "s",
      scope: "messages:read",
      codeChallenge: "cc",
      csrfToken: "csrf",
      deviceId: "d1",
      nowMs: 1,
      expiresAtMs: 2,
    })
    store.createAuthRequest({
      id: "ar2",
      clientId: "c1",
      redirectUri: "https://example.com/cb",
      state: "s",
      scope: "messages:read",
      codeChallenge: "cc",
      csrfToken: "csrf",
      deviceId: "d1",
      nowMs: 1,
      expiresAtMs: 1,
    })
    store.createAuthRequest({
      id: "ar3",
      clientId: "c1",
      redirectUri: "https://example.com/cb",
      state: "s",
      scope: "messages:read",
      codeChallenge: "cc",
      csrfToken: "csrf",
      deviceId: "d1",
      nowMs: 1,
      expiresAtMs: 999,
    })
    store.createAuthCode({
      code: "code1",
      grantId: "g1",
      clientId: "c1",
      redirectUri: "https://example.com/cb",
      codeChallenge: "cc",
      nowMs: 1,
      expiresAtMs: 2,
    })
    store.createAuthCode({
      code: "code2",
      grantId: "g1",
      clientId: "c1",
      redirectUri: "https://example.com/cb",
      codeChallenge: "cc",
      nowMs: 1,
      expiresAtMs: 999,
    })

    expect(store.getAuthRequest("ar1", 1)).not.toBeNull()
    expect(store.getAuthCode("code1", 1)).not.toBeNull()

    store.cleanupExpired(2)
    expect(store.getAuthRequest("ar1", 1)).toBeNull()
    expect(store.getAuthRequest("ar2", 1)).toBeNull()
    expect(store.getAuthCode("code1", 1)).toBeNull()

    // Not expired; should remain.
    expect(store.getAuthRequest("ar3", 1)).not.toBeNull()
    expect(store.getAuthCode("code2", 1)).not.toBeNull()
  })

  it("no-op updates on missing ids", () => {
    const store = createMemoryStore()
    store.setAuthRequestEmail("missing", "a@example.com")
    store.setAuthRequestInlineTokenEnc("missing", "enc")
    store.setAuthRequestInlineUserId("missing", 1n)
    store.markAuthCodeUsed("missing", 1)
  })
})
