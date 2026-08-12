import { encrypt } from "../modules/encryption/encryption"
import { decrypt } from "../modules/encryption/encryption"

interface EncryptedData {
  encrypted: Buffer
  iv: Buffer
  authTag: Buffer
}

export interface OAuthTokenEnvelope {
  readonly data: Record<string, unknown>
}

export function encryptLinearTokens(tokens: OAuthTokenEnvelope): EncryptedData {
  const data = tokens.data as Record<string, unknown>
  const encryptedToken = encrypt(JSON.stringify({
    data: {
      ...data,
      obtained_at: Math.floor(Date.now() / 1_000),
    },
  }))
  return {
    encrypted: encryptedToken.encrypted,
    iv: encryptedToken.iv,
    authTag: encryptedToken.authTag,
  }
}

export function decryptLinearTokens(encryptedData: EncryptedData) {
  const decryptedToken = decrypt({
    encrypted: encryptedData.encrypted,
    iv: encryptedData.iv,
    authTag: encryptedData.authTag,
  })

  const parsedToken = JSON.parse(decryptedToken)

  return parsedToken
}
