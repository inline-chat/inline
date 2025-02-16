import * as arctic from "arctic"
import { encrypt } from "../../modules/encryption/encryption"
import { decrypt } from "../../modules/encryption/encryption"

interface EncryptedData {
  encrypted: Buffer
  iv: Buffer
  authTag: Buffer
}

export function encryptLinearTokens(tokens: arctic.OAuth2Tokens): EncryptedData {
  const encryptedToken = encrypt(JSON.stringify(tokens))
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
