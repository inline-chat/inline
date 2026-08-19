import { expect, test } from "bun:test"
import { parse } from "dotenv"
import { loadInlineProtocolConfiguration } from "../src/modules/inlineProtocol/config"
import { makeInlineProtocolRsaSigner } from "../src/modules/inlineProtocol/rsaSigner"
import { createInlineProtocolKeyBundle, environmentPayload, publicRingsMatch } from "./inline-protocol-keys"

test("copy-environment payload round-trips through dotenv and server decoders", () => {
  const bundle = createInlineProtocolKeyBundle()
  const environment = parse(environmentPayload(bundle))
  const configuration = loadInlineProtocolConfiguration(environment)

  expect(configuration.enabled).toBe(true)
  if (!configuration.enabled) throw new Error("Inline Protocol configuration unexpectedly disabled")

  expect(makeInlineProtocolRsaSigner(configuration.rsaPrivateKeysJson).publicKeyRing).toHaveLength(2)
  expect(configuration.authKeyKekRing.activeId).toBe(bundle.authKeyKekRing.activeId)
  expect(configuration.authCodePepperRing.activeId).toBe(bundle.authCodePepperRing.activeId)
})

test("public-ring comparison covers modulus, exponent, fingerprint, and order", () => {
  const ring = {
    rsaPublicKeyRing: [{ modulus: "modulus", exponent: "AQAB", fingerprint: "123" }],
  }
  expect(publicRingsMatch(ring, structuredClone(ring))).toBeTrue()
  expect(publicRingsMatch(ring, {
    rsaPublicKeyRing: [{ ...ring.rsaPublicKeyRing[0]!, modulus: "different" }],
  })).toBeFalse()
})
