import { describe, expect, test } from "bun:test"
import { constants, generateKeyPairSync, publicEncrypt } from "node:crypto"
import { makeInlineProtocolRsaSigner } from "./rsaSigner"

const makePem = () => {
  const pair = generateKeyPairSync("rsa", { modulusLength: 2048, publicExponent: 65537 })
  return {
    privateKeyPem: pair.privateKey.export({ format: "pem", type: "pkcs8" }).toString(),
    publicKey: pair.publicKey,
  }
}

describe("Inline Protocol RSA signer boundary", () => {
  test("advertises an overlapping ring and performs only raw private exponentiation", async () => {
    const first = makePem()
    const second = makePem()
    const signer = makeInlineProtocolRsaSigner(JSON.stringify([
      { privateKeyPem: first.privateKeyPem },
      { privateKeyPem: second.privateKeyPem },
    ]))
    expect(signer.publicKeyRing.length).toBe(2)
    const plaintext = Buffer.alloc(256)
    plaintext[255] = 42
    const ciphertext = publicEncrypt({ key: first.publicKey, padding: constants.RSA_NO_PADDING }, plaintext)
    expect(await signer.handshakeKeys[0]!.rawDecrypt(ciphertext)).toEqual(Uint8Array.from(plaintext))
  })

  test("rejects a one-key production ring but permits it for fixtures", () => {
    const key = makePem()
    const json = JSON.stringify([{ privateKeyPem: key.privateKeyPem }])
    expect(() => makeInlineProtocolRsaSigner(json)).toThrow()
    expect(makeInlineProtocolRsaSigner(json, { requireOverlappingRing: false }).publicKeyRing.length).toBe(1)
  })
})
