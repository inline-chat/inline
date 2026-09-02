import { sha256 } from "@noble/hashes/sha2.js"
import { Method, type FileMessageLocation, type GetFilePartInput, type GetFilePartResult, type RpcCall, type RpcResult } from "./core.js"
import { INLINE_TRANSFER_MAX_LOCATOR_ID, INLINE_TRANSFER_PART_SIZE } from "./transfers.js"

export const MAX_DOWNLOAD_PART_SIZE = INLINE_TRANSFER_PART_SIZE

export interface NativeDownloadRpcTransport {
  /** Must settle on abort and enforce a bounded individual RPC deadline. */
  getPart(input: GetFilePartInput, signal?: AbortSignal): Promise<GetFilePartResult>
}

export type NativeDownloadInput = {
  fileUniqueId: string
  message?: FileMessageLocation
  /** Resume at a byte offset durably written by the caller. */
  offset?: bigint
  signal?: AbortSignal
}

export class NativeDownloadError extends Error {
  constructor(readonly code: "invalid_input" | "protocol" | "integrity", message: string) {
    super(message)
    this.name = `NativeDownloadError:${code}`
  }
}

type PartOutcome = { part: GetFilePartResult; error?: never } | { error: unknown; part?: never }

/** Opt-in, ordered range streaming. The caller owns persistence and resume checkpoints. */
export class NativeDownloadClient {
  constructor(
    private readonly rpc: NativeDownloadRpcTransport,
    private readonly concurrency = 3,
    private readonly partSize = MAX_DOWNLOAD_PART_SIZE,
  ) {
    if (!Number.isInteger(concurrency) || concurrency < 1 || concurrency > 8 ||
        partSize !== INLINE_TRANSFER_PART_SIZE) {
      throw new TypeError("Invalid download concurrency or part size")
    }
  }

  async *download(input: NativeDownloadInput): AsyncGenerator<GetFilePartResult> {
    const fileUniqueId = input.fileUniqueId
    const message = input.message ? { ...input.message } : undefined
    const signal = input.signal
    const offset = input.offset ?? 0n
    if (!/^[A-Za-z0-9_-]{6,128}$/.test(input.fileUniqueId) || offset < 0n ||
        (message && (message.chatId < 1n || message.chatId > INLINE_TRANSFER_MAX_LOCATOR_ID ||
          message.messageId < 1n || message.messageId > INLINE_TRANSFER_MAX_LOCATOR_ID)) ||
        offset > BigInt(Number.MAX_SAFE_INTEGER)) {
      throw new NativeDownloadError("invalid_input", "Invalid file ID or download offset")
    }
    const controller = new AbortController()
    const abort = () => controller.abort(signal?.reason)
    signal?.addEventListener("abort", abort, { once: true })
    if (signal?.aborted) abort()
    const pending: Promise<PartOutcome>[] = []
    const request = (at: bigint): Promise<PartOutcome> => this.rpc.getPart({
      fileUniqueId, message, offset: at, limit: this.partSize,
    }, controller.signal).then((part) => ({ part }), (error: unknown) => ({ error }))
    try {
      controller.signal.throwIfAborted()
      // Discover representation length with the first actual range, without a
      // separate metadata round trip or speculatively reading beyond EOF.
      const first = await request(offset)
      controller.signal.throwIfAborted()
      if ("error" in first) throw first.error
      validatePart(first.part, offset, this.partSize)
      const total = first.part.totalSize
      let next = offset + BigInt(first.part.data.length)
      const fill = () => {
        while (pending.length < this.concurrency && next < total) {
          pending.push(request(next))
          next += BigInt(this.partSize)
        }
      }
      // Include the chunk handed to the consumer in the bounded window.
      yield first.part
      controller.signal.throwIfAborted()
      fill()
      let expected = offset + BigInt(first.part.data.length)
      while (pending.length > 0) {
        const outcome = await pending.shift()!
        controller.signal.throwIfAborted()
        if ("error" in outcome) throw outcome.error
        validatePart(outcome.part, expected, this.partSize, total)
        expected += BigInt(outcome.part.data.length)
        yield outcome.part
        controller.signal.throwIfAborted()
        fill()
      }
    } finally {
      signal?.removeEventListener("abort", abort)
      controller.abort()
      // Every scheduled promise has a rejection handler; drain transport work
      // before returning ownership to a caller that breaks out of iteration.
      await Promise.all(pending)
    }
  }
}

function validatePart(part: GetFilePartResult, offset: bigint, limit: number, total?: bigint) {
  if (part.offset !== offset || part.totalSize < offset || part.totalSize <= 0n ||
      part.totalSize > BigInt(Number.MAX_SAFE_INTEGER) || (total !== undefined && part.totalSize !== total)) {
    throw new NativeDownloadError("protocol", "Invalid download range or changed file size")
  }
  const expected = Number(part.totalSize - offset > BigInt(limit) ? BigInt(limit) : part.totalSize - offset)
  if (part.data.length !== expected || part.sha256.length !== 32) {
    throw new NativeDownloadError("protocol", "Invalid download length or digest")
  }
  const digest = sha256(part.data)
  if (!digest.every((byte, index) => byte === part.sha256[index])) {
    throw new NativeDownloadError("integrity", "Download chunk digest does not match")
  }
}

export const rpcDownloadTransport = (
  call: (method: Method, input: RpcCall["input"], signal?: AbortSignal) => Promise<RpcResult["result"]>,
): NativeDownloadRpcTransport => ({
  async getPart(input, signal) {
    const result = await call(Method.GET_FILE_PART, { oneofKind: "getFilePart", getFilePart: input }, signal)
    if (result.oneofKind !== "getFilePart") {
      throw new NativeDownloadError("protocol", "Unexpected getFilePart result")
    }
    return result.getFilePart
  },
})
