import {
  Method,
  UploadKind,
  UploadStatus,
  type CancelUploadResult,
  type CreateUploadInput,
  type CreateUploadResult,
  type FinishUploadResult,
  type GetFilePartInput,
  type GetFilePartResult,
  type GetUploadStateResult,
  type RpcCall,
  type RpcResult,
  type SaveUploadPartInput,
  type UploadComplete,
} from "@inline-chat/protocol/core"
import { bytesEqual, randomBytes, sha256, toHex } from "../bytes"
import { MAX_UPLOAD_PARTS, PART_SIZE } from "../constants"
import type { MediaClock } from "../types"

/**
 * An in-memory transfer server for media tests. It follows the server's upload
 * state machine (`server/src/modules/uploads/operations.ts` and
 * `db/models/inlineUploads.ts`): `CreateUpload` is idempotent per session and
 * client upload ID, parts are acknowledged only once stored, a duplicate part
 * is `alreadyPresent`, finish is idempotent, idle uploads expire after 24 h
 * and every upload after 7 days. It also serves `GET_FILE_PART` and signed
 * HTTP range requests like `/file` (`modules/files/mediaResponse.ts`).
 *
 * Faults are scripted per call: fail before applying, lose the reply after
 * applying, delay on the virtual clock, or hold until the test releases.
 */

export class TransferServerError extends Error {
  constructor(readonly code: "bad_request" | "transport" | "rate_limit" | "aborted", message: string = code) {
    super(message)
    this.name = `TransferServerError:${code}`
  }
}

type UploadRow = {
  uploadId: Uint8Array
  session: string
  clientUploadId: Uint8Array
  input: CreateUploadInput
  byteCount: number
  partCount: number
  parts: Map<number, Uint8Array>
  status: "uploading" | "processing" | "complete" | "failed" | "canceled"
  expiresAt: number
  hardExpiresAt: number
  processingRounds: number
  complete?: UploadComplete
  failure?: { code: number; retryable: boolean }
}

export type StoredFile = { bytes: Uint8Array; mimeType: string }

export type FaultKind = "fail-before" | "lose-reply" | "hold-before" | "hold-after" | "delay"

export type Fault = {
  method: Method
  kind: FaultKind
  /** Which calls of that method it applies to; all by default. */
  when?: (input: RpcCall["input"]) => boolean
  /** How many matching calls it affects. Default 1. */
  times?: number
  /** For `delay`. */
  ms?: number
  /**
   * For `hold-before`: the request is already on the wire. The client may give
   * up on it, but it still reaches the server when released (a late duplicate).
   */
  detached?: boolean
}

export type HeldCall = {
  readonly method: Method
  readonly input: RpcCall["input"]
  /** Lets the call go on (`hold-before`) or delivers its reply (`hold-after`). */
  release(): void
  /** Drops the call: the client sees a lost connection. */
  drop(): void
}

export type HttpFault =
  | { kind: "status"; status: number; times?: number }
  | { kind: "truncate"; times?: number }
  | { kind: "wrong-total"; total: number; times?: number }
  | { kind: "ignore-range"; times?: number }
  | { kind: "delay"; ms: number; times?: number }
  | { kind: "error-mid-body"; times?: number }

const IDLE_TTL_MS = 24 * 60 * 60 * 1_000
const HARD_TTL_MS = 7 * 24 * 60 * 60 * 1_000
const STREAM_CHUNK = 64 * 1024

const badRequest = (message = "bad request") => new TransferServerError("bad_request", message)

const sameMetadata = (left: CreateUploadInput, right: CreateUploadInput) =>
  left.fileName === right.fileName && left.mimeType === right.mimeType && left.byteCount === right.byteCount &&
  left.kind === right.kind && bytesEqual(left.sha256, right.sha256)

export class TransferServer {
  /** The authenticated session. Uploads belong to the session that created them, like the server's owner check. */
  session = "session-1"
  /** Rounds of `processing` before a finish completes. */
  processingRounds = 0
  /** Per-call latency on the virtual clock. */
  latency: (method: Method, input: RpcCall["input"]) => number = () => 0
  /** Accept `inline_data` on create. Off simulates a server that predates it. */
  acceptsInlineData = true
  /** Make finalization fail with this failure. */
  finalizationFailure: { code: number; retryable: boolean } | undefined

  readonly uploads = new Map<string, UploadRow>()
  readonly files = new Map<string, StoredFile>()
  readonly calls: { method: Method; input: RpcCall["input"] }[] = []
  /** Files created by finalization. Exactly-once means this never repeats an upload. */
  readonly finalized: string[] = []
  duplicateParts = 0
  readonly httpRequests: { url: string; range: string | null; ifRange: string | null }[] = []
  #faults: (Fault & { remaining: number })[] = []
  #httpFaults: (HttpFault & { remaining: number })[] = []
  readonly #held: HeldCall[] = []
  #linkVersion = 1

  constructor(readonly clock: MediaClock) {}

  // Faults

  fault(fault: Fault): this {
    this.#faults.push({ ...fault, remaining: fault.times ?? 1 })
    return this
  }

  httpFault(fault: HttpFault): this {
    this.#httpFaults.push({ ...fault, remaining: fault.times ?? 1 })
    return this
  }

  held(): readonly HeldCall[] {
    return this.#held
  }

  /** Ends an upload's life now, as the server's expiry would. */
  expire(uploadId: Uint8Array): void {
    const row = this.uploads.get(toHex(uploadId))
    if (row) row.expiresAt = this.clock.now()
  }

  callsOf(method: Method): RpcCall["input"][] {
    return this.calls.filter((call) => call.method === method).map((call) => call.input)
  }

  #takeFault(method: Method, input: RpcCall["input"]): Fault | undefined {
    const index = this.#faults.findIndex((fault) => fault.method === method && (fault.when?.(input) ?? true))
    if (index < 0) return undefined
    const fault = this.#faults[index]!
    fault.remaining -= 1
    if (fault.remaining <= 0) this.#faults.splice(index, 1)
    return fault
  }

  // RPC

  /** The `MediaRpcCall` the client is given. */
  readonly call = async (method: Method, input: RpcCall["input"], signal?: AbortSignal): Promise<RpcResult["result"]> => {
    this.calls.push({ method, input })
    const fault = this.#takeFault(method, input)
    const latency = this.latency(method, input) + (fault?.kind === "delay" ? fault.ms ?? 0 : 0)
    if (latency > 0) await this.#wait(latency, signal)
    if (signal?.aborted) throw new TransferServerError("aborted")
    if (fault?.kind === "fail-before") throw new TransferServerError("transport", "connection lost before the request arrived")
    if (fault?.kind === "hold-before" && fault.detached) return await this.#detached(method, input, signal)
    if (fault?.kind === "hold-before") await this.#hold(method, input, signal)
    const result = this.#apply(method, input)
    if (fault?.kind === "lose-reply") throw new TransferServerError("transport", "connection lost before the reply")
    if (fault?.kind === "hold-after") await this.#hold(method, input, signal)
    if (signal?.aborted) throw new TransferServerError("aborted")
    return result
  }

  #wait(ms: number, signal?: AbortSignal): Promise<void> {
    return new Promise((resolve, reject) => {
      const onAbort = () => {
        this.clock.clearTimeout(timer)
        reject(new TransferServerError("aborted"))
      }
      const timer = this.clock.setTimeout(() => {
        signal?.removeEventListener("abort", onAbort)
        resolve()
      }, ms)
      signal?.addEventListener("abort", onAbort, { once: true })
    })
  }

  #hold(method: Method, input: RpcCall["input"], signal?: AbortSignal): Promise<void> {
    return new Promise((resolve, reject) => {
      const held: HeldCall = {
        method,
        input,
        release: () => {
          this.#unhold(held)
          resolve()
        },
        drop: () => {
          this.#unhold(held)
          reject(new TransferServerError("transport", "connection lost"))
        },
      }
      signal?.addEventListener("abort", () => {
        this.#unhold(held)
        reject(new TransferServerError("aborted"))
      }, { once: true })
      this.#held.push(held)
    })
  }

  /** The client's promise settles on abort; the request itself applies whenever it is released. */
  #detached(method: Method, input: RpcCall["input"], signal?: AbortSignal): Promise<RpcResult["result"]> {
    return new Promise((resolve, reject) => {
      let settled = false
      const held: HeldCall = {
        method,
        input,
        release: () => {
          this.#unhold(held)
          try {
            const result = this.#apply(method, input)
            if (!settled) resolve(result)
          } catch (error) {
            if (!settled) reject(error)
          }
          settled = true
        },
        drop: () => {
          this.#unhold(held)
          if (!settled) reject(new TransferServerError("transport", "connection lost"))
          settled = true
        },
      }
      signal?.addEventListener("abort", () => {
        if (settled) return
        settled = true
        reject(new TransferServerError("aborted"))
      }, { once: true })
      this.#held.push(held)
    })
  }

  #unhold(held: HeldCall): void {
    const index = this.#held.indexOf(held)
    if (index >= 0) this.#held.splice(index, 1)
  }

  #apply(method: Method, input: RpcCall["input"]): RpcResult["result"] {
    switch (method) {
      case Method.CREATE_UPLOAD:
        if (input.oneofKind !== "createUpload") throw badRequest()
        return { oneofKind: "createUpload", createUpload: this.#create(input.createUpload) }
      case Method.SAVE_UPLOAD_PART:
        if (input.oneofKind !== "saveUploadPart") throw badRequest()
        return { oneofKind: "saveUploadPart", saveUploadPart: this.#savePart(input.saveUploadPart) }
      case Method.GET_UPLOAD_STATE:
        if (input.oneofKind !== "getUploadState") throw badRequest()
        return { oneofKind: "getUploadState", getUploadState: this.#state(input.getUploadState.uploadId) }
      case Method.FINISH_UPLOAD:
        if (input.oneofKind !== "finishUpload") throw badRequest()
        return { oneofKind: "finishUpload", finishUpload: this.#finish(input.finishUpload.uploadId) }
      case Method.CANCEL_UPLOAD:
        if (input.oneofKind !== "cancelUpload") throw badRequest()
        return { oneofKind: "cancelUpload", cancelUpload: this.#cancel(input.cancelUpload.uploadId) }
      case Method.GET_FILE_PART:
        if (input.oneofKind !== "getFilePart") throw badRequest()
        return { oneofKind: "getFilePart", getFilePart: this.#getPart(input.getFilePart) }
      default:
        throw badRequest("unsupported method")
    }
  }

  #row(uploadId: Uint8Array): UploadRow {
    const row = this.uploads.get(toHex(uploadId))
    if (!row || row.session !== this.session) throw badRequest("unknown upload")
    return row
  }

  #expired(row: UploadRow): boolean {
    const now = this.clock.now()
    return row.expiresAt <= now || row.hardExpiresAt <= now
  }

  #create(input: CreateUploadInput): CreateUploadResult {
    const byteCount = Number(input.byteCount)
    const partCount = Math.ceil(byteCount / PART_SIZE)
    if (input.clientUploadId.length !== 16 || input.sha256.length !== 32 || byteCount <= 0 ||
        partCount > MAX_UPLOAD_PARTS || !input.fileName.trim() || input.kind === UploadKind.UNSPECIFIED) throw badRequest()
    if (input.kind === UploadKind.PHOTO && input.mimeType !== "image/jpeg" && input.mimeType !== "image/png") throw badRequest()
    if (input.inlineData !== undefined && (input.inlineData.length !== byteCount || byteCount > PART_SIZE)) throw badRequest()
    let row = [...this.uploads.values()].find((candidate) =>
      candidate.session === this.session && bytesEqual(candidate.clientUploadId, input.clientUploadId))
    if (row && !sameMetadata(row.input, input)) throw badRequest("metadata conflict")
    if (!row) {
      const now = this.clock.now()
      row = {
        uploadId: randomBytes(16),
        session: this.session,
        clientUploadId: input.clientUploadId.slice(),
        input: { ...input, inlineData: undefined },
        byteCount,
        partCount,
        parts: new Map(),
        status: "uploading",
        expiresAt: now + IDLE_TTL_MS,
        hardExpiresAt: now + HARD_TTL_MS,
        processingRounds: this.processingRounds,
      }
      this.uploads.set(toHex(row.uploadId), row)
    }
    const created: CreateUploadResult = {
      uploadId: row.uploadId.slice(),
      partSize: PART_SIZE,
      partCount: row.partCount,
      expiresAt: BigInt(Math.floor(row.expiresAt / 1_000)),
      acceptedParts: [...row.parts.keys()].sort((a, b) => a - b),
    }
    if (input.inlineData === undefined || !this.acceptsInlineData || row.partCount !== 1) return created
    try {
      if (!row.parts.has(0)) this.#savePart({ uploadId: row.uploadId, partIndex: 0, data: input.inlineData })
      const finished = this.#finish(row.uploadId)
      if (finished.state.oneofKind === "complete") return { ...created, acceptedParts: [0], complete: finished.state.complete }
      return { ...created, acceptedParts: [0] }
    } catch {
      return created
    }
  }

  #savePart(input: SaveUploadPartInput): { alreadyPresent: boolean } {
    const row = this.#row(input.uploadId)
    if (row.status === "processing" || row.status === "complete") {
      if (row.parts.has(input.partIndex)) {
        this.duplicateParts += 1
        return { alreadyPresent: true }
      }
      throw badRequest()
    }
    if (row.status !== "uploading" || this.#expired(row)) throw badRequest("upload is not accepting parts")
    const expected = Math.min(PART_SIZE, row.byteCount - input.partIndex * PART_SIZE)
    if (!Number.isInteger(input.partIndex) || input.partIndex < 0 || input.partIndex >= row.partCount || input.data.length !== expected) {
      throw badRequest("bad part")
    }
    const existing = row.parts.get(input.partIndex)
    if (existing) {
      if (!bytesEqual(existing, input.data)) throw badRequest("part conflict")
      this.duplicateParts += 1
      return { alreadyPresent: true }
    }
    row.parts.set(input.partIndex, input.data.slice())
    row.expiresAt = Math.min(row.hardExpiresAt, this.clock.now() + IDLE_TTL_MS)
    return { alreadyPresent: false }
  }

  #state(uploadId: Uint8Array): GetUploadStateResult {
    const row = this.#row(uploadId)
    const acceptedParts = [...row.parts.keys()].sort((a, b) => a - b)
    if (row.status === "uploading" && this.#expired(row)) return { status: UploadStatus.EXPIRED, acceptedParts }
    switch (row.status) {
      case "uploading": return { status: UploadStatus.UPLOADING, acceptedParts }
      case "processing": return { status: UploadStatus.PROCESSING, acceptedParts }
      case "canceled": return { status: UploadStatus.CANCELED, acceptedParts }
      case "failed": return { status: UploadStatus.FAILED, acceptedParts, failure: row.failure }
      case "complete": return { status: UploadStatus.COMPLETE, acceptedParts, complete: row.complete }
    }
  }

  #finish(uploadId: Uint8Array): FinishUploadResult {
    const row = this.#row(uploadId)
    if (row.status === "complete") return { state: { oneofKind: "complete", complete: row.complete! } }
    if (row.status === "failed") return { state: { oneofKind: "failed", failed: row.failure! } }
    if (row.status === "canceled" || (row.status === "uploading" && this.#expired(row))) throw badRequest("rejected")
    if (row.status === "uploading") {
      const missing: number[] = []
      for (let index = 0; index < row.partCount; index += 1) if (!row.parts.has(index)) missing.push(index)
      if (missing.length > 0) return { state: { oneofKind: "missing", missing: { partIndices: missing } } }
      row.status = "processing"
    }
    if (row.processingRounds > 0) {
      row.processingRounds -= 1
      return { state: { oneofKind: "processing", processing: { retryAfterSeconds: 1 } } }
    }
    return this.#finalize(row)
  }

  #finalize(row: UploadRow): FinishUploadResult {
    const body = new Uint8Array(row.byteCount)
    for (const [index, part] of row.parts) body.set(part, index * PART_SIZE)
    if (this.finalizationFailure) {
      row.status = "failed"
      row.failure = this.finalizationFailure
      return { state: { oneofKind: "failed", failed: row.failure } }
    }
    if (!bytesEqual(sha256(body), row.input.sha256)) {
      row.status = "failed"
      row.failure = { code: 1, retryable: false }
      return { state: { oneofKind: "failed", failed: row.failure } }
    }
    const fileUniqueId = `F${toHex(row.uploadId).slice(0, 16)}`
    this.files.set(fileUniqueId, { bytes: body, mimeType: row.input.mimeType })
    this.finalized.push(fileUniqueId)
    row.status = "complete"
    row.complete = { fileUniqueId, media: { oneofKind: undefined } }
    return { state: { oneofKind: "complete", complete: row.complete } }
  }

  #cancel(uploadId: Uint8Array): CancelUploadResult {
    const row = this.#row(uploadId)
    if (row.status === "uploading" || row.status === "processing") {
      row.status = "canceled"
      row.parts.clear()
      return { canceled: true, alreadyTerminal: false }
    }
    return { canceled: false, alreadyTerminal: true }
  }

  #getPart(input: GetFilePartInput): GetFilePartResult {
    const file = this.files.get(input.fileUniqueId)
    if (!file) throw badRequest("unknown file")
    const total = file.bytes.length
    const offset = Number(input.offset)
    if (offset > total || input.limit < 1 || input.limit > PART_SIZE) throw badRequest()
    const data = file.bytes.slice(offset, Math.min(total, offset + input.limit))
    return { offset: input.offset, totalSize: BigInt(total), data, sha256: sha256(data) }
  }

  // HTTP

  addFile(fileUniqueId: string, bytes: Uint8Array, mimeType = "application/octet-stream"): void {
    this.files.set(fileUniqueId, { bytes: bytes.slice(), mimeType })
  }

  /** A signed media URL, valid until `expireLinks`. */
  fileUrl(fileUniqueId: string): string {
    return `https://media.test/file?id=${fileUniqueId}&sig=${this.#linkVersion}`
  }

  /** Every URL handed out so far is now rejected with 403, as an expired signature is. */
  expireLinks(): void {
    this.#linkVersion += 1
  }

  static entityTag(fileUniqueId: string, size: number): string {
    return `"${fileUniqueId}-${size}"`
  }

  #takeHttpFault(): HttpFault | undefined {
    const fault = this.#httpFaults[0]
    if (!fault) return undefined
    fault.remaining -= 1
    if (fault.remaining <= 0) this.#httpFaults.shift()
    return fault
  }

  /** The `fetch` the client is given. */
  readonly fetch = async (url: string, init: RequestInit = {}): Promise<Response> => {
    const headers = new Headers(init.headers)
    this.httpRequests.push({ url, range: headers.get("range"), ifRange: headers.get("if-range") })
    const signal = init.signal ?? undefined
    const fault = this.#takeHttpFault()
    if (fault?.kind === "delay") await this.#wait(fault.ms, signal)
    if (signal?.aborted) throw new DOMException("The operation was aborted", "AbortError")
    if (fault?.kind === "status") return new Response("fault", { status: fault.status })
    const parsed = new URL(url)
    const id = parsed.searchParams.get("id") ?? ""
    if (parsed.searchParams.get("sig") !== String(this.#linkVersion)) return new Response("forbidden", { status: 403 })
    const file = this.files.get(id)
    if (!file) return new Response("not_found", { status: 404 })
    const total = file.bytes.length
    const etag = TransferServer.entityTag(id, total)
    const common = { "accept-ranges": "bytes", etag, "content-type": file.mimeType, "content-security-policy": "sandbox" }
    const rangeHeader = headers.get("range")
    const ifRange = headers.get("if-range")
    const useRange = rangeHeader && (!ifRange || ifRange === etag) && fault?.kind !== "ignore-range"
    let start = 0
    let end = total - 1
    if (useRange) {
      const match = /^bytes=(\d+)-(\d*)$/.exec(rangeHeader)
      if (!match || Number(match[1]) >= total) {
        return new Response("range_not_satisfiable", { status: 416, headers: { ...common, "content-range": `bytes */${total}` } })
      }
      start = Number(match[1])
      end = match[2] ? Math.min(Number(match[2]), total - 1) : total - 1
    }
    let body = file.bytes.slice(start, end + 1)
    const reportedTotal = fault?.kind === "wrong-total" ? fault.total : total
    const length = body.length
    if (fault?.kind === "truncate") body = body.slice(0, Math.floor(body.length / 2))
    const stream = this.#stream(body, signal, fault?.kind === "error-mid-body")
    if (useRange) {
      return new Response(stream, {
        status: 206,
        headers: { ...common, "content-length": String(length), "content-range": `bytes ${start}-${end}/${reportedTotal}` },
      })
    }
    return new Response(stream, { status: 200, headers: { ...common, "content-length": String(length) } })
  }

  #stream(body: Uint8Array, signal: AbortSignal | undefined, failMidway: boolean): ReadableStream<Uint8Array> {
    let offset = 0
    return new ReadableStream<Uint8Array>({
      pull: (controller) => {
        if (signal?.aborted) {
          controller.error(new DOMException("The operation was aborted", "AbortError"))
          return
        }
        if (failMidway && offset >= body.length / 2) {
          controller.error(new TypeError("network error"))
          return
        }
        if (offset >= body.length) {
          controller.close()
          return
        }
        const chunk = body.slice(offset, Math.min(body.length, offset + STREAM_CHUNK))
        offset += chunk.length
        controller.enqueue(chunk)
      },
    })
  }
}

/** Deterministic test bytes: `length` bytes from a simple generator. */
export const testBytes = (length: number, seed = 1): Uint8Array => {
  const out = new Uint8Array(length)
  let state = seed >>> 0 || 1
  for (let index = 0; index < length; index += 1) {
    state = (Math.imul(state, 1_103_515_245) + 12_345) >>> 0
    out[index] = state >>> 24
  }
  return out
}
