import {
  HttpUploadKind,
  type CreateHttpUploadRequest,
  type CreateHttpUploadResult,
  type FinishHttpUploadRequest,
  type FinishHttpUploadResult,
} from "@inline-chat/protocol/core"
import { createHash } from "node:crypto"
import { createWriteStream } from "node:fs"
import { mkdtemp, rmdir, unlink } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { Readable, Transform } from "node:stream"
import { pipeline } from "node:stream/promises"
import { API_BASE_URL } from "@in/server/env"
import { MAX_FILE_SIZE } from "@in/server/config"
import {
  InlineProtocolUploadRepository,
  type ClaimedInlineProtocolUpload,
  type InlineProtocolUploadIdentity,
  type InlineProtocolUploadMetadata,
  type InlineProtocolUploadOwner,
} from "@in/server/db/models/inlineProtocolUploads"
import { uploadFileOperation } from "@in/server/methods/uploadFileOperation"
import { ApiError, InlineError } from "@in/server/types/errors"
import type { InlineProtocolApplicationContext } from "./application"

const HTTP_UPLOAD_PATH_PREFIX = "/v3/uploads/"
const UPLOAD_RETRY_AFTER_SECONDS = 2

const decodeBase64UrlExact = (value: string): Uint8Array | undefined => {
  if (!/^[A-Za-z0-9_-]+$/.test(value)) return undefined
  const decoded = Buffer.from(value, "base64url")
  return decoded.toString("base64url") === value ? Uint8Array.from(decoded) : undefined
}

const kindForRequest = (kind: HttpUploadKind): InlineProtocolUploadMetadata["kind"] | undefined => {
  switch (kind) {
    case HttpUploadKind.PHOTO: return "photo"
    case HttpUploadKind.VIDEO: return "video"
    case HttpUploadKind.DOCUMENT: return "document"
    case HttpUploadKind.VOICE: return "voice"
    default: return undefined
  }
}

const requireBoundIdentity = (context: InlineProtocolApplicationContext): InlineProtocolUploadIdentity => {
  const authorization = context.authorization
  if (!authorization.temporaryBound || authorization.permanent ||
      authorization.userId === undefined || authorization.accountSessionId === undefined ||
      authorization.authKeyId.length !== 8 || authorization.permanentAuthKeyId?.length !== 8) {
    throw new InlineError(ApiError.UNAUTHORIZED)
  }
  return {
    userId: authorization.userId,
    accountSessionId: authorization.accountSessionId,
    permanentAuthKeyId: authorization.permanentAuthKeyId,
    temporaryAuthKeyId: authorization.authKeyId,
  }
}

const requireBoundOwner = (context: InlineProtocolApplicationContext): InlineProtocolUploadOwner => {
  const { temporaryAuthKeyId: _, ...owner } = requireBoundIdentity(context)
  return owner
}

const validateMetadata = (request: CreateHttpUploadRequest): InlineProtocolUploadMetadata => {
  const fileName = request.fileName.trim()
  const mimeType = request.mimeType.trim().toLowerCase()
  const kind = kindForRequest(request.kind)
  if (!fileName || fileName.length > 255 || fileName.includes("\0") ||
      !mimeType || mimeType.length > 255 || request.byteCount <= 0n ||
      request.byteCount > BigInt(MAX_FILE_SIZE) || request.sha256.length !== 32 || !kind) {
    throw new InlineError(request.byteCount > BigInt(MAX_FILE_SIZE) ? ApiError.FILE_TOO_LARGE : ApiError.BAD_REQUEST)
  }
  return { fileName, mimeType, byteCount: request.byteCount, sha256: request.sha256.slice(), kind }
}

const genericResponse = (status: number, headers?: HeadersInit): Response =>
  new Response(null, { status, headers })

export class InlineProtocolUploadOperations {
  constructor(
    private readonly repository: Pick<
      InlineProtocolUploadRepository,
      "create" | "claim" | "complete" | "release" | "finish"
    >,
    private readonly apiBaseUrl = API_BASE_URL,
    private readonly upload = uploadFileOperation,
  ) {}

  async create(
    request: CreateHttpUploadRequest,
    context: InlineProtocolApplicationContext,
  ): Promise<CreateHttpUploadResult> {
    const identity = requireBoundIdentity(context)
    const created = await this.repository.create(identity, validateMetadata(request))
    const encodedUploadId = Buffer.from(created.uploadId).toString("base64url")
    return {
      uploadId: created.uploadId,
      uploadUrl: new URL(`${HTTP_UPLOAD_PATH_PREFIX}${encodedUploadId}`, this.apiBaseUrl).toString(),
      capability: created.capability,
      expiresAt: BigInt(Math.floor(created.expiresAt.getTime() / 1_000)),
    }
  }

  async finish(
    request: FinishHttpUploadRequest,
    context: InlineProtocolApplicationContext,
  ): Promise<FinishHttpUploadResult> {
    // The permanent device authorization and account session own the intent.
    // Its issuing temporary key is audit data, not a rotation-sensitive capability.
    const state = await this.repository.finish(request.uploadId, requireBoundOwner(context))
    if (state.kind === "rejected") throw new InlineError(ApiError.FILE_NOT_FOUND)
    return state.kind === "complete"
      ? { state: { oneofKind: "complete", complete: { fileUniqueId: state.fileUniqueId } } }
      : { state: { oneofKind: "pending", pending: { retryAfterSeconds: UPLOAD_RETRY_AFTER_SECONDS } } }
  }

  async handleHttp(request: Request, clientIp?: string): Promise<Response | undefined> {
    const url = new URL(request.url)
    if (!url.pathname.startsWith(HTTP_UPLOAD_PATH_PREFIX)) return undefined
    if (request.method !== "PUT") return genericResponse(405, { Allow: "PUT" })
    const encodedUploadId = url.pathname.slice(HTTP_UPLOAD_PATH_PREFIX.length)
    if (!encodedUploadId || encodedUploadId.includes("/")) return genericResponse(404)
    const uploadId = decodeBase64UrlExact(encodedUploadId)
    const authorization = request.headers.get("authorization")
    const capability = authorization?.startsWith("InlineUpload ")
      ? decodeBase64UrlExact(authorization.slice("InlineUpload ".length))
      : undefined
    if (!uploadId || !capability) return genericResponse(404)

    const claim = await this.repository.claim(uploadId, capability)
    if (claim.kind === "rejected") return genericResponse(404)
    if (claim.kind === "complete") return genericResponse(204)
    if (claim.kind === "busy") {
      return genericResponse(409, { "Retry-After": String(UPLOAD_RETRY_AFTER_SECONDS) })
    }
    return this.#consumeClaimedUpload(request, claim.upload, clientIp)
  }

  async #consumeClaimedUpload(
    request: Request,
    upload: ClaimedInlineProtocolUpload,
    clientIp?: string,
  ): Promise<Response> {
    const contentLength = request.headers.get("content-length")
    let declaredLength: bigint | undefined
    try {
      declaredLength = contentLength && /^\d+$/.test(contentLength) ? BigInt(contentLength) : undefined
    } catch {
      declaredLength = undefined
    }
    if (declaredLength !== upload.byteCount || request.headers.get("content-type") !== upload.mimeType || !request.body) {
      await this.repository.release(upload)
      return genericResponse(400)
    }

    const directory = await mkdtemp(join(tmpdir(), "inline-protocol-upload-"))
    const filePath = join(directory, "body")
    let shouldRelease = true
    try {
      const digest = createHash("sha256")
      let received = 0n
      const meter = new Transform({
        transform(chunk: Buffer, _encoding, callback) {
          received += BigInt(chunk.length)
          if (received > upload.byteCount) {
            callback(new RangeError("Upload body exceeds declared length"))
            return
          }
          digest.update(chunk)
          callback(null, chunk)
        },
      })
      await pipeline(
        Readable.fromWeb(request.body as never),
        meter,
        createWriteStream(filePath, { flags: "wx" }),
      )
      if (received !== upload.byteCount || !digest.digest().equals(Buffer.from(upload.sha256))) {
        return genericResponse(400)
      }
      const file = new File([Bun.file(filePath)], upload.fileName, { type: upload.mimeType })
      const result = await this.upload({ type: upload.kind, file }, {
        currentUserId: upload.userId,
        currentSessionId: upload.accountSessionId,
        ip: clientIp,
      })
      if (!await this.repository.complete(upload, result.fileUniqueId)) {
        throw new Error("Inline Protocol upload lease was lost before completion")
      }
      shouldRelease = false
      return genericResponse(204)
    } catch (error) {
      if (error instanceof RangeError) return genericResponse(400)
      throw error
    } finally {
      if (shouldRelease) await this.repository.release(upload).catch(() => {})
      await unlink(filePath).catch(() => {})
      await rmdir(directory).catch(() => {})
    }
  }
}
