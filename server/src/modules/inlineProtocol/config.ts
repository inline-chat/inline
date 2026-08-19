import { InlineProtocolConfigurationError } from "./errors"
import { decodeInlineProtocolSecretKeyRing, type InlineProtocolSecretKeyRing } from "./keyCipher"

export type InlineProtocolDisabledConfiguration = { enabled: false }
export type InlineProtocolEnabledConfiguration = {
  enabled: true
  requireCanonicalPublicRing: boolean
  rsaPrivateKeysJson: string
  authKeyKekRing: InlineProtocolSecretKeyRing
  authCodePepperRing: InlineProtocolSecretKeyRing
}
export type InlineProtocolConfiguration =
  | InlineProtocolDisabledConfiguration
  | InlineProtocolEnabledConfiguration

type InlineProtocolEnvironment = Readonly<Record<string, string | undefined>>

const requiredRing = (environment: InlineProtocolEnvironment, name: string): InlineProtocolSecretKeyRing => {
  const value = environment[name]
  if (!value) throw new InlineProtocolConfigurationError({ reason: `${name} is required when V3 is enabled` })
  return decodeInlineProtocolSecretKeyRing(value, name)
}

export const loadInlineProtocolConfiguration = (
  environment: InlineProtocolEnvironment = process.env,
): InlineProtocolConfiguration => {
  const rsaPrivateKeysJson = environment["INLINE_PROTOCOL_RSA_PRIVATE_KEYS_JSON"]
  const hasAnyCredential = Boolean(
    rsaPrivateKeysJson ||
    environment["INLINE_PROTOCOL_AUTH_KEY_KEK_RING_JSON"] ||
    environment["INLINE_PROTOCOL_AUTH_CODE_PEPPER_RING_JSON"],
  )
  if (environment["NODE_ENV"] !== "production" && !hasAnyCredential) return { enabled: false }
  if (!rsaPrivateKeysJson) {
    throw new InlineProtocolConfigurationError({
      reason: "INLINE_PROTOCOL_RSA_PRIVATE_KEYS_JSON is required in production",
    })
  }
  return {
    enabled: true,
    // Local plaintext Debug endpoints intentionally publish process-local
    // verification keys. Every production endpoint must match the release
    // clients' pinned overlapping ring before the listener becomes ready.
    requireCanonicalPublicRing: environment["NODE_ENV"] === "production",
    rsaPrivateKeysJson,
    authKeyKekRing: requiredRing(environment, "INLINE_PROTOCOL_AUTH_KEY_KEK_RING_JSON"),
    authCodePepperRing: requiredRing(environment, "INLINE_PROTOCOL_AUTH_CODE_PEPPER_RING_JSON"),
  }
}
