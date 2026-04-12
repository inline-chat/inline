import { API_BASE_URL, FILES_PROXY_SIGNING_KEY, R2_SECRET_ACCESS_KEY } from "@in/server/env"
import { FILES_PATH_PREFIX, USE_PHOTO_PROXY } from "@in/server/config"
import { getR2 } from "@in/server/libs/r2"
import { decrypt } from "@in/server/modules/encryption/encryption"
import { createHmac, timingSafeEqual } from "node:crypto"

export { FILES_PATH_PREFIX } from "@in/server/config"

const DEFAULT_URL_EXPIRY_SECONDS = 60 * 60 * 24 * 7 // 1 week
const mediaProxySigningKey = FILES_PROXY_SIGNING_KEY ?? R2_SECRET_ACCESS_KEY ?? ""
export const PHOTO_MEDIA_ROUTE_PATH = "/file"
const FILE_UNIQUE_ID_RE = /^[A-Za-z0-9_-]{6,128}$/

type PhotoUrlSource =
  | string
  | {
      fileUniqueId: string
      path?: string | null
      pathEncrypted?: Buffer | null
      pathIv?: Buffer | null
      pathTag?: Buffer | null
    }

export const getSignedUrl = (path: string, expiresInSeconds: number = DEFAULT_URL_EXPIRY_SECONDS) => {
  let r2 = getR2()
  if (!r2) return null

  let url = r2.file(`${FILES_PATH_PREFIX}/${path}`).presign({
    acl: "public-read",
    expiresIn: Math.max(1, Math.floor(expiresInSeconds)),
  })
  return url
}

const signMediaProxyPayload = ({ payload, signingKey }: { payload: string; signingKey: string }): string => {
  if (!signingKey) return ""
  return createHmac("sha256", signingKey).update(payload).digest("base64url")
}

const createPhotoPayload = ({ fileUniqueId, exp }: { fileUniqueId: string; exp: number }): string => {
  return JSON.stringify({ id: fileUniqueId, e: exp })
}

export const getSignedMediaPhotoUrl = (
  file: PhotoUrlSource,
  expiresInSeconds: number = DEFAULT_URL_EXPIRY_SECONDS,
  options?: { baseUrl?: string; signingKey?: string; now?: number; useProxy?: boolean },
): string | null => {
  const fileUniqueId = getPhotoFileUniqueId(file)
  if (!FILE_UNIQUE_ID_RE.test(fileUniqueId)) return null

  if (!(options?.useProxy ?? USE_PHOTO_PROXY)) {
    const path = getPhotoPath(file)
    if (!path) return null
    return getSignedUrl(path, expiresInSeconds)
  }

  const signingKey = options?.signingKey ?? mediaProxySigningKey
  if (!signingKey) return null

  const nowSec = options?.now ?? Math.floor(Date.now() / 1000)
  const exp = nowSec + Math.max(1, Math.floor(expiresInSeconds))
  const payload = createPhotoPayload({ fileUniqueId, exp })
  const sig = signMediaProxyPayload({ payload, signingKey })
  if (!sig) return null

  const url = new URL(PHOTO_MEDIA_ROUTE_PATH, options?.baseUrl ?? API_BASE_URL)
  url.searchParams.set("id", fileUniqueId)
  url.searchParams.set("exp", String(exp))
  url.searchParams.set("sig", sig)
  return url.toString()
}

export const verifySignedMediaPhotoUrl = ({
  fileUniqueId,
  exp,
  sig,
  now,
  signingKey,
}: {
  fileUniqueId: string
  exp: number
  sig: string
  now?: number
  signingKey?: string
}): boolean => {
  const key = signingKey ?? mediaProxySigningKey
  if (!key) return false
  if (!FILE_UNIQUE_ID_RE.test(fileUniqueId)) return false
  if (!Number.isFinite(exp)) return false
  if (!sig || sig.length > 256) return false

  const nowSec = now ?? Math.floor(Date.now() / 1000)
  if (exp < nowSec) return false

  const payload = createPhotoPayload({ fileUniqueId, exp })
  const expectedSig = signMediaProxyPayload({ payload, signingKey: key })
  if (!expectedSig) return false

  const expected = Buffer.from(expectedSig)
  const provided = Buffer.from(sig)
  if (expected.length !== provided.length) return false
  return timingSafeEqual(expected, provided)
}

const getPhotoFileUniqueId = (file: PhotoUrlSource): string => {
  return typeof file === "string" ? file : file.fileUniqueId
}

const getPhotoPath = (file: PhotoUrlSource): string | null => {
  if (typeof file === "string") return null
  if (file.path) return file.path
  if (!file.pathEncrypted || !file.pathIv || !file.pathTag) return null

  try {
    return decrypt({
      encrypted: file.pathEncrypted,
      iv: file.pathIv,
      authTag: file.pathTag,
    })
  } catch {
    return null
  }
}
