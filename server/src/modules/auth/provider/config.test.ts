import { describe, expect, test } from "bun:test"
import { createPrivateKey, generateKeyPairSync } from "node:crypto"
import {
  decodeApplePrivateKey,
  requireProviderAuthConfig,
  type ProviderAuthConfig,
} from "./config"

function privateKeyPem(namedCurve: "prime256v1" | "secp384r1"): string {
  const { privateKey } = generateKeyPairSync("ec", { namedCurve })
  return privateKey.export({ format: "pem", type: "pkcs8" }).toString()
}

describe("Apple provider private key", () => {
  test("decodes escaped-newline PKCS#8 PEM to P-256 DER", () => {
    const der = decodeApplePrivateKey(privateKeyPem("prime256v1").replaceAll("\n", "\\n"))
    const imported = createPrivateKey({ key: Buffer.from(der), format: "der", type: "pkcs8" })

    expect(imported.asymmetricKeyType).toBe("ec")
    expect(imported.asymmetricKeyDetails?.namedCurve).toBe("prime256v1")
  })

  test("rejects malformed private keys without echoing their contents", () => {
    const secret = "not-a-private-key"
    expect(() => decodeApplePrivateKey(secret)).toThrow("valid PKCS#8 PEM private key")
    try {
      decodeApplePrivateKey(secret)
    } catch (error) {
      expect(String(error)).not.toContain(secret)
    }
  })

  test("rejects EC keys on the wrong curve", () => {
    expect(() => decodeApplePrivateKey(privateKeyPem("secp384r1"))).toThrow("P-256")
  })
})

describe("required provider authentication configuration", () => {
  const configured = (): ProviderAuthConfig => ({
    baseUrl: "https://api.inline.test",
    attemptTtlMs: 60_000,
    google: { clientId: "google-client", clientSecret: "google-secret" },
    apple: {
      clientId: "apple-client",
      teamId: "apple-team",
      keyId: "apple-key",
      privateKey: new Uint8Array([1, 2, 3]),
    },
  })

  test("requires Google because supported clients expose its sign-in button", () => {
    expect(() => requireProviderAuthConfig({ ...configured(), google: null }))
      .toThrow("GOOGLE_AUTH_CLIENT_ID and GOOGLE_AUTH_CLIENT_SECRET")
  })

  test("requires Apple because supported clients expose its sign-in button", () => {
    expect(() => requireProviderAuthConfig({ ...configured(), apple: null }))
      .toThrow("APPLE_AUTH_PRIVATE_KEY")
  })

  test("returns a fully typed configuration when both providers are available", () => {
    const config = requireProviderAuthConfig(configured())
    expect(config.google.clientId).toBe("google-client")
    expect(config.apple.keyId).toBe("apple-key")
  })
})
