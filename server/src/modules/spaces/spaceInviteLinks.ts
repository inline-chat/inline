import { createHash, randomBytes } from "node:crypto"
import { Encryption2 } from "@in/server/modules/encryption/encryption2"
import { normalizeSpaceHandle } from "@in/server/modules/spaces/spaceHandle"

export const SPACE_INVITE_TOKEN_PREFIX = "iv1_"
export const SPACE_INVITE_TOKEN_BYTES = 32
export const SPACE_INVITE_DEFAULT_EXPIRY_MS = 7 * 24 * 60 * 60 * 1_000

const tokenPattern = /^iv1_[A-Za-z0-9_-]{43}$/
const publicHandlePattern = /^[A-Za-z0-9][A-Za-z0-9_-]{1,63}$/

export const isValidSpaceInviteToken = (token: string): boolean => tokenPattern.test(token)

export const normalizePublicJoinHandle = (handle: string): string | null => {
  const normalized = normalizeSpaceHandle(handle)
  return normalized && publicHandlePattern.test(normalized) ? normalized : null
}

export const isValidPublicJoinHandle = (handle: string): boolean =>
  normalizePublicJoinHandle(handle) !== null

export const generateSpaceInviteToken = (): string =>
  `${SPACE_INVITE_TOKEN_PREFIX}${randomBytes(SPACE_INVITE_TOKEN_BYTES).toString("base64url")}`

export const hashSpaceInviteToken = (token: string): Buffer =>
  createHash("sha256").update(token, "utf8").digest()

export const encryptSpaceInviteToken = (token: string): Buffer =>
  Encryption2.encrypt(Buffer.from(token, "utf8"))

export const decryptSpaceInviteToken = (encrypted: Buffer): string =>
  Encryption2.decryptToString(encrypted)

export const publicSpaceInviteUrl = (handle: string): string =>
  `https://inline.chat/s/${encodeURIComponent(handle)}`

export const privateSpaceInviteUrl = (token: string): string =>
  `https://inline.chat/invite/${encodeURIComponent(token)}`
