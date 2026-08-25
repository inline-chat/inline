import { afterEach, describe, expect, test } from "bun:test"
import {
  SignJWT,
  createLocalJWKSet,
  decodeProtectedHeader,
  decodeJwt,
  exportJWK,
  exportPKCS8,
  generateKeyPair,
} from "jose"
import { verifyAppleIdToken } from "./claims"
import {
  createAppleClientSecret,
  exchangeNativeAppleAuthorizationCode,
  nativeAppleClientIdFromIdentityToken,
  verifyNativeAppleAuthorization,
} from "./nativeApple"

const originalDateNow = Date.now

afterEach(() => {
  Date.now = originalDateNow
})

async function testAppleConfig() {
  const { privateKey } = await generateKeyPair("ES256", { extractable: true })
  const pem = await exportPKCS8(privateKey)
  const der = Buffer.from(
    pem.replace(/-----[^-]+-----|\s/g, ""),
    "base64",
  )
  return {
    clientId: "chat.inline.auth",
    nativeClientIds: ["chat.inline.InlineIOS", "chat.inline.InlineIOS.debug"],
    teamId: "TEAM123456",
    keyId: "KEY1234567",
    privateKey: new Uint8Array(der),
  }
}

function unsignedToken(audience: string | string[]): string {
  const header = Buffer.from(JSON.stringify({ alg: "none" })).toString("base64url")
  const payload = Buffer.from(JSON.stringify({ aud: audience })).toString("base64url")
  return `${header}.${payload}.`
}

async function signedAppleToken(input: {
  privateKey: CryptoKey
  audience?: string
  subject?: string
  nonce?: string
  email?: string
}): Promise<string> {
  return new SignJWT({
    nonce: input.nonce ?? "native-apple-nonce",
    email: input.email ?? "person@example.com",
    email_verified: "true",
  })
    .setProtectedHeader({ alg: "RS256", kid: "apple-test-key" })
    .setIssuer("https://appleid.apple.com")
    .setAudience(input.audience ?? "chat.inline.InlineIOS")
    .setSubject(input.subject ?? "apple-subject")
    .setIssuedAt()
    .setExpirationTime("5m")
    .sign(input.privateKey)
}

describe("native Apple provider proof", () => {
  test("selects only an explicitly allowed native audience", () => {
    const allowed = ["chat.inline.InlineIOS", "chat.inline.InlineIOS.debug"]
    expect(nativeAppleClientIdFromIdentityToken(unsignedToken(allowed[0]!), allowed)).toBe(allowed[0]!)
    expect(() => nativeAppleClientIdFromIdentityToken(unsignedToken("chat.attacker.app"), allowed)).toThrow(
      "unsupported native audience",
    )
    expect(() => nativeAppleClientIdFromIdentityToken(unsignedToken(allowed), allowed)).toThrow(
      "unsupported native audience",
    )
  })

  test("creates a short-lived Apple client secret for the native App ID", async () => {
    Date.now = () => 2_000_000_000_000
    const config = await testAppleConfig()
    const token = await createAppleClientSecret(config, "chat.inline.InlineIOS")
    expect(decodeProtectedHeader(token)).toMatchObject({ alg: "ES256", kid: config.keyId, typ: "JWT" })
    expect(decodeJwt(token)).toMatchObject({
      iss: config.teamId,
      aud: "https://appleid.apple.com",
      sub: "chat.inline.InlineIOS",
      iat: 2_000_000_000,
      exp: 2_000_000_300,
    })
  })

  test("exchanges a native code without a browser redirect URI", async () => {
    const config = await testAppleConfig()
    let requestBody: URLSearchParams | undefined
    const idToken = unsignedToken("chat.inline.InlineIOS")
    const exchanged = await exchangeNativeAppleAuthorizationCode({
      code: "single-use-code",
      clientId: "chat.inline.InlineIOS",
      config,
      fetcher: async (_url, init) => {
        requestBody = init?.body as URLSearchParams
        return Response.json({ id_token: idToken })
      },
    })
    expect(exchanged).toBe(idToken)
    expect(requestBody?.get("grant_type")).toBe("authorization_code")
    expect(requestBody?.get("client_id")).toBe("chat.inline.InlineIOS")
    expect(requestBody?.get("code")).toBe("single-use-code")
    expect(requestBody?.has("client_secret")).toBe(true)
    expect(requestBody?.has("redirect_uri")).toBe(false)
  })

  test("verifies both signed Apple tokens against the native audience, nonce, and subject", async () => {
    const config = await testAppleConfig()
    const { publicKey, privateKey } = await generateKeyPair("RS256", { extractable: true })
    const publicJwk = await exportJWK(publicKey)
    const keyResolver = createLocalJWKSet({
      keys: [{ ...publicJwk, kid: "apple-test-key", alg: "RS256", use: "sig" }],
    })
    const identityToken = await signedAppleToken({
      privateKey,
      email: "Person@Example.com",
    })
    const exchangedToken = await signedAppleToken({ privateKey })
    let requestBody: URLSearchParams | undefined

    const claims = await verifyNativeAppleAuthorization({
      code: "single-use-code",
      identityToken,
      nonce: "native-apple-nonce",
      firstName: " Person ",
      lastName: " Example ",
      config,
      fetcher: async (_url, init) => {
        requestBody = init?.body as URLSearchParams
        return Response.json({ id_token: exchangedToken })
      },
      verifyIdToken: (input) => verifyAppleIdToken({ ...input, keyResolver }),
    })

    expect(claims).toMatchObject({
      provider: "apple",
      subject: "apple-subject",
      email: "person@example.com",
      authoritativeEmail: true,
      firstName: "Person",
      lastName: "Example",
    })
    expect(requestBody?.get("code")).toBe("single-use-code")
    expect(requestBody?.get("client_id")).toBe("chat.inline.InlineIOS")
  })

  test("rejects a signed native Apple identity token with the wrong nonce", async () => {
    const config = await testAppleConfig()
    const { publicKey, privateKey } = await generateKeyPair("RS256", { extractable: true })
    const publicJwk = await exportJWK(publicKey)
    const keyResolver = createLocalJWKSet({
      keys: [{ ...publicJwk, kid: "apple-test-key", alg: "RS256", use: "sig" }],
    })
    const identityToken = await signedAppleToken({ privateKey, nonce: "wrong-nonce" })

    await expect(verifyNativeAppleAuthorization({
      code: "single-use-code",
      identityToken,
      nonce: "native-apple-nonce",
      config,
      fetcher: async () => Response.json({ id_token: identityToken }),
      verifyIdToken: (input) => verifyAppleIdToken({ ...input, keyResolver }),
    })).rejects.toThrow("invalid subject or nonce")
  })

  test("rejects when the authorization code resolves to a different Apple subject", async () => {
    const config = await testAppleConfig()
    const { publicKey, privateKey } = await generateKeyPair("RS256", { extractable: true })
    const publicJwk = await exportJWK(publicKey)
    const keyResolver = createLocalJWKSet({
      keys: [{ ...publicJwk, kid: "apple-test-key", alg: "RS256", use: "sig" }],
    })
    const identityToken = await signedAppleToken({ privateKey })
    const exchangedToken = await signedAppleToken({ privateKey, subject: "different-apple-subject" })

    await expect(verifyNativeAppleAuthorization({
      code: "single-use-code",
      identityToken,
      nonce: "native-apple-nonce",
      config,
      fetcher: async () => Response.json({ id_token: exchangedToken }),
      verifyIdToken: (input) => verifyAppleIdToken({ ...input, keyResolver }),
    })).rejects.toThrow("do not identify the same user")
  })
})
