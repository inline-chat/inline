import {
  constants,
  createPrivateKey,
  createPublicKey,
  privateDecrypt,
  type KeyObject,
} from "node:crypto"
import {
  makeRsaPublicKey,
  type HandshakeRsaServerKey,
} from "@inline-chat/protocol/secure"
import { InlineProtocolConfigurationError, InlineProtocolFailure } from "./errors"

type RsaPrivateKeyConfiguration = {
  privateKeyPem: string
  advertise?: boolean
}

export type InlineProtocolPublicRsaKey = {
  modulus: string
  exponent: string
  fingerprint: string
}

export interface InlineProtocolRsaSigner {
  handshakeKeys: readonly HandshakeRsaServerKey[]
  publicKeyRing: readonly InlineProtocolPublicRsaKey[]
}

const decodeConfiguration = (json: string): RsaPrivateKeyConfiguration[] => {
  let decoded: unknown
  try {
    decoded = JSON.parse(json)
  } catch (cause) {
    throw new InlineProtocolConfigurationError({ reason: "RSA key JSON is malformed", cause })
  }
  if (!Array.isArray(decoded)) {
    throw new InlineProtocolConfigurationError({ reason: "RSA key JSON must be an array" })
  }
  return decoded.map((value) => {
    if (typeof value !== "object" || value === null ||
        typeof (value as { privateKeyPem?: unknown }).privateKeyPem !== "string" ||
        ((value as { advertise?: unknown }).advertise !== undefined &&
          typeof (value as { advertise?: unknown }).advertise !== "boolean")) {
      throw new InlineProtocolConfigurationError({ reason: "RSA key entry is invalid" })
    }
    return value as RsaPrivateKeyConfiguration
  })
}

const keyProfile = (privateKey: KeyObject): HandshakeRsaServerKey => {
  let jwk: JsonWebKey
  try {
    jwk = createPublicKey(privateKey).export({ format: "jwk" })
  } catch (cause) {
    throw new InlineProtocolConfigurationError({ reason: "RSA public key export failed", cause })
  }
  if (jwk.kty !== "RSA" || typeof jwk.n !== "string" || typeof jwk.e !== "string") {
    throw new InlineProtocolConfigurationError({ reason: "configured private key is not RSA" })
  }
  const modulus = Uint8Array.from(Buffer.from(jwk.n, "base64url"))
  const exponent = Uint8Array.from(Buffer.from(jwk.e, "base64url"))
  if (modulus.length !== 256) {
    throw new InlineProtocolConfigurationError({ reason: "RSA key must be exactly 2048 bits" })
  }
  const profile = makeRsaPublicKey(modulus, exponent)
  return {
    ...profile,
    rawDecrypt: async (ciphertext) => {
      if (ciphertext.length !== 256) throw new InlineProtocolFailure({ phase: "rsa_decrypt" })
      try {
        const plaintext = privateDecrypt({ key: privateKey, padding: constants.RSA_NO_PADDING }, ciphertext)
        if (plaintext.length !== 256) throw new InlineProtocolFailure({ phase: "rsa_decrypt_length" })
        return Uint8Array.from(plaintext)
      } catch (cause) {
        if (cause instanceof InlineProtocolFailure) throw cause
        throw new InlineProtocolFailure({ phase: "rsa_decrypt", cause })
      }
    },
  }
}

export const makeInlineProtocolRsaSigner = (
  json: string,
  {
    requireOverlappingRing = true,
    requiredPublicRing,
  }: {
    requireOverlappingRing?: boolean
    requiredPublicRing?: readonly InlineProtocolPublicRsaKey[]
  } = {},
): InlineProtocolRsaSigner => {
  const configured = decodeConfiguration(json)
  const keys = configured.map((configuration) => {
    try {
      return { configuration, key: keyProfile(createPrivateKey(configuration.privateKeyPem)) }
    } catch (cause) {
      if (cause instanceof InlineProtocolConfigurationError) throw cause
      throw new InlineProtocolConfigurationError({ reason: "RSA private key import failed", cause })
    }
  })
  const advertised = keys.filter(({ configuration }) => configuration.advertise !== false).map(({ key }) => key)
  if (advertised.length < (requireOverlappingRing ? 2 : 1)) {
    throw new InlineProtocolConfigurationError({ reason: "RSA key ring has insufficient advertised keys" })
  }
  const fingerprints = new Set(advertised.map((key) => key.fingerprint.toString()))
  if (fingerprints.size !== advertised.length) {
    throw new InlineProtocolConfigurationError({ reason: "RSA key ring contains duplicate fingerprints" })
  }
  const signer: InlineProtocolRsaSigner = {
    handshakeKeys: advertised,
    publicKeyRing: advertised.map((key) => ({
      modulus: Buffer.from(key.modulus).toString("base64url"),
      exponent: Buffer.from(key.exponent).toString("base64url"),
      fingerprint: key.fingerprint.toString(),
    })),
  }
  if (requiredPublicRing && JSON.stringify(signer.publicKeyRing) !== JSON.stringify(requiredPublicRing)) {
    throw new InlineProtocolConfigurationError({
      reason: "configured RSA key ring does not match the canonical client ring",
    })
  }
  return signer
}
