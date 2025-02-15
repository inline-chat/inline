import { decrypt, EmptyEncryptedData, encrypt, type EncryptedData, type OptionalEncryptedData } from "./encryption"

export const encryptMessage = (text: string): OptionalEncryptedData => {
  if (!text) {
    return EmptyEncryptedData
  }

  return encrypt(text)
}

export const decryptMessage = (data: EncryptedData): string => {
  return decrypt(data)
}
