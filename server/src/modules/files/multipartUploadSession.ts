import { createHmac, timingSafeEqual } from "crypto"
import { R2_SECRET_ACCESS_KEY } from "@in/server/env"

const SESSION_TOKEN_VERSION = 1
const SESSION_TTL_SECONDS = 60 * 60 * 4

const getSessionSecret = (): string => {
  if (R2_SECRET_ACCESS_KEY && R2_SECRET_ACCESS_KEY.length > 0) {
    return R2_SECRET_ACCESS_KEY
  }

  return "inline-dev-upload-session-secret"
}

export type VideoMultipartSession = {
  v: number
  userId: number
  uploadId: string
  fileUniqueId: string
  path: string
  bucketPath: string
  fileName: string
  mimeType: string
  extension: string
  fileSize: number
  width: number
  height: number
  duration: number
  partSize: number
  totalParts: number
  createdAt: number
  expiresAt: number
}

const signPayload = (payloadEncoded: string): string => {
  return createHmac("sha256", getSessionSecret()).update(payloadEncoded).digest("base64url")
}

export const createVideoMultipartSessionToken = (
  payload: Omit<VideoMultipartSession, "v" | "createdAt" | "expiresAt">,
): string => {
  const createdAt = Math.floor(Date.now() / 1000)
  const sessionPayload: VideoMultipartSession = {
    ...payload,
    v: SESSION_TOKEN_VERSION,
    createdAt,
    expiresAt: createdAt + SESSION_TTL_SECONDS,
  }

  const payloadEncoded = Buffer.from(JSON.stringify(sessionPayload), "utf8").toString("base64url")
  const signature = signPayload(payloadEncoded)
  return `${payloadEncoded}.${signature}`
}

export const verifyVideoMultipartSessionToken = (token: string): VideoMultipartSession | null => {
  const splitIndex = token.lastIndexOf(".")
  if (splitIndex <= 0 || splitIndex >= token.length - 1) {
    return null
  }

  const payloadEncoded = token.slice(0, splitIndex)
  const providedSignature = token.slice(splitIndex + 1)
  const expectedSignature = signPayload(payloadEncoded)

  const providedBuffer = Buffer.from(providedSignature, "utf8")
  const expectedBuffer = Buffer.from(expectedSignature, "utf8")

  if (providedBuffer.length !== expectedBuffer.length) {
    return null
  }

  if (!timingSafeEqual(providedBuffer, expectedBuffer)) {
    return null
  }

  let payload: VideoMultipartSession
  try {
    payload = JSON.parse(Buffer.from(payloadEncoded, "base64url").toString("utf8"))
  } catch {
    return null
  }

  if (!payload || payload.v !== SESSION_TOKEN_VERSION) {
    return null
  }

  const now = Math.floor(Date.now() / 1000)
  if (!Number.isInteger(payload.expiresAt) || payload.expiresAt <= now) {
    return null
  }

  return payload
}
