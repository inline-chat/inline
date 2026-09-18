import { customType } from "drizzle-orm/pg-core"
import {
  contentEncryptionWritesEnabled, openContent, openContentText, sealContent, sealContentText,
} from "../../modules/encryption/contentEncryption"

/** Drizzle applies these codecs to inserts, updates, projections and relational reads. */
export const encryptedText = (name: string, purpose: string, maxCharacters?: number) => customType<{ data: string; driverData: string }>({
  dataType: () => "text",
  toDriver: (value) => {
    if (maxCharacters !== undefined && Array.from(value).length > maxCharacters) {
      throw new Error("Content exceeds storage character limit")
    }
    return contentEncryptionWritesEnabled() ? sealContentText(value, purpose) : value
  },
  fromDriver: (value) => openContentText(value, purpose),
})(name)

export const encryptedBytes = (name: string, purpose: string) => customType<{ data: Buffer; driverData: Buffer | string }>({
  dataType: () => "bytea",
  toDriver: (value) => contentEncryptionWritesEnabled() ? sealContent(value, purpose) : value,
  fromDriver: (value) => openContent(
    typeof value === "string" ? Buffer.from(value.replace(/^\\x/, ""), "hex") : value,
    purpose,
  ),
})(name)
