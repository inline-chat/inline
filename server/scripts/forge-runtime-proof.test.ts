import { expect, it } from "bun:test"
import vector from "./fixtures/forge-nested-digest.json"
import { createApnRequire, verifyForgeBundle, verifyForgeSource } from "./forge-runtime-proof"

type Digest = { update: (value: string) => Digest; digest: () => { getBytes: () => string; toHex: () => string } }
type Forge = {
  jsbn: { BigInteger: new (value: string, radix: number) => unknown }
  md: { sha256: { create: () => Digest } }
  util: { hexToBytes: (value: string) => string }
  pki: { rsa: {
    setPublicKey: (n: unknown, e: unknown) => { verify: (digest: string, signature: string) => boolean }
    setPrivateKey: (n: unknown, e: unknown, d: unknown) => { sign: (digest: Digest | string, scheme?: string) => string }
  } }
}
const require = createApnRequire()
const forge = require("node-forge") as Forge
const n = new forge.jsbn.BigInteger(vector.n, 16)
const e = new forge.jsbn.BigInteger(vector.e, 16)
const d = new forge.jsbn.BigInteger(vector.d, 16)
const publicKey = forge.pki.rsa.setPublicKey(n, e)
const privateKey = forge.pki.rsa.setPrivateKey(n, e, d)
const digest = () => forge.md.sha256.create().update(vector.message)

it("uses the exact reviewed upstream Forge source through APNs", () => {
  expect(verifyForgeSource()).toMatchObject({ package: "node-forge", version: "1.4.1-0" })
})

it("rejects the real upstream RSA forgery using the installed verifier", () => {
  // This same ordinary verify call returns true on unpatched Forge 1.4.0.
  expect(() => publicKey.verify(digest().digest().getBytes(), forge.util.hexToBytes(vector.forged)))
    .toThrow("DigestInfo")
  expect(publicKey.verify(digest().digest().getBytes(), privateKey.sign(digest()))).toBe(true)
})

it("accepts valid AlgorithmIdentifiers and rejects extra children with and without NULL", () => {
  const sequence = (hex: string) => `30${(hex.length / 2).toString(16).padStart(2, "0")}${hex}`
  for (const withNull of [false, true]) {
    for (const extraChild of [false, true]) {
      const algorithm = "0609608648016503040201" + (withNull ? "0500" : "") + (extraChild ? "020100" : "")
      const encoded = sequence(sequence(algorithm) + "0420" + digest().digest().toHex())
      const signature = privateKey.sign(forge.util.hexToBytes(encoded), "NONE")
      const verify = () => publicKey.verify(digest().digest().getBytes(), signature)
      if (extraChild) expect(verify).toThrow("DigestInfo")
      else expect(verify()).toBe(true)
    }
  }
})

it("retains the verifier fix through the production Bun bundler", async () => {
  const build = await Bun.build({ entrypoints: [require.resolve("node-forge")], target: "bun" })
  expect(build.success).toBe(true)
  expect(build.outputs).toHaveLength(1)
  verifyForgeBundle(await build.outputs[0]!.text())
})
