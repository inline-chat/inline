import { createHash } from "node:crypto"
import type { GetFilePartInput, GetFilePartResult } from "@inline-chat/protocol/core"
import { getR2 } from "@in/server/libs/r2"
import { decrypt } from "@in/server/modules/encryption/encryption"
import { FILES_PATH_PREFIX } from "@in/server/config"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import type { HandlerContext } from "@in/server/realtime/types"
import { resolveDownloadFile } from "./downloadAccess"
import { readFileBytes } from "./readFileBytes"
import { INLINE_TRANSFER_MAX_LOCATOR_ID, INLINE_TRANSFER_PART_SIZE } from "@inline-chat/protocol/transfers"

export const MAX_DOWNLOAD_PART_SIZE = INLINE_TRANSFER_PART_SIZE
const MAX_DOWNLOADS_PER_SESSION = 8
const MAX_CONCURRENT_DOWNLOADS = 64

const checkAbort = (signal?: AbortSignal) => signal?.throwIfAborted()

const readFromStorage = async (path: string, offset: number, length: number, signal?: AbortSignal) => {
  checkAbort(signal)
  const r2 = getR2()
  if (!r2) throw RealtimeRpcError.InternalError()
  return readFileBytes(r2.file(path).slice(offset, offset + length).stream(), length, signal)
}

export class NativeDownloadOperations {
  #active = 0
  readonly #sessions = new Map<number, number>()

  constructor(
    private readonly resolveFile = resolveDownloadFile,
    private readonly readRange = readFromStorage,
  ) {}

  async getPart(input: GetFilePartInput, context: HandlerContext): Promise<GetFilePartResult> {
    // This additive byte route requires the encrypted V3 carrier and its
    // application deadline; the shared legacy dispatcher has neither.
    if (!context.inlineProtocol) throw RealtimeRpcError.BadRequest()
    if (!/^[A-Za-z0-9_-]{6,128}$/.test(input.fileUniqueId) ||
        input.offset < 0n || input.offset > BigInt(Number.MAX_SAFE_INTEGER) ||
        !Number.isInteger(input.limit) || input.limit < 1 || input.limit > MAX_DOWNLOAD_PART_SIZE ||
        (input.message && [input.message.chatId, input.message.messageId].some(
          (id) => id <= 0n || id > INLINE_TRANSFER_MAX_LOCATOR_ID,
        ))) throw RealtimeRpcError.BadRequest()
    checkAbort(context.signal)
    const active = this.#sessions.get(context.sessionId) ?? 0
    if (active >= MAX_DOWNLOADS_PER_SESSION || this.#active >= MAX_CONCURRENT_DOWNLOADS) {
      throw RealtimeRpcError.RateLimit()
    }
    this.#active += 1
    this.#sessions.set(context.sessionId, active + 1)
    try {
      const file = await this.resolveFile(input.fileUniqueId, context.userId, input.message)
      checkAbort(context.signal)
      // Unknown and inaccessible IDs have exactly the same response.
      if (!file) throw RealtimeRpcError.BadRequest()
      const size = file.fileSize
      if (size === null || !Number.isSafeInteger(size) || size <= 0 ||
          !file.pathEncrypted || !file.pathIv || !file.pathTag) throw RealtimeRpcError.BadRequest()
      if (input.offset > BigInt(size)) throw RealtimeRpcError.BadRequest()
      const offset = Number(input.offset)
      const length = Math.min(input.limit, size - offset)
      const path = decrypt({ encrypted: file.pathEncrypted, iv: file.pathIv, authTag: file.pathTag })
      const data = length === 0 ? new Uint8Array() :
        await this.readRange(`${FILES_PATH_PREFIX}/${path}`, offset, length, context.signal)
      checkAbort(context.signal)
      if (data.length !== length) throw RealtimeRpcError.InternalError()
      return { offset: input.offset, totalSize: BigInt(size), data, sha256: createHash("sha256").update(data).digest() }
    } finally {
      this.#active -= 1
      const remaining = (this.#sessions.get(context.sessionId) ?? 1) - 1
      if (remaining === 0) this.#sessions.delete(context.sessionId)
      else this.#sessions.set(context.sessionId, remaining)
    }
  }
}

export const nativeDownloadOperations = new NativeDownloadOperations()
