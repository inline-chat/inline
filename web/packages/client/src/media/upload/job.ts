import type { UploadComplete, UploadKind, UploadVideoMetadata, UploadVoiceMetadata } from "@inline-chat/protocol/core"
import { decodeRecord, encodeRecord } from "../bytes"
import type { ByteStore } from "../store/byte-store"

/**
 * One upload's durable record. Unsent attachments are obligations, not cache:
 * the source bytes stay until the job completes or is canceled.
 *
 * - `staged`: the source blob and this row exist; nothing was sent.
 * - `uploading`: a create was attempted (`uploadId` may still be unknown when its reply was lost).
 * - `finishing`: every part is accepted; finish or processing is in progress.
 * - `paused`: a transient failure; retried automatically up to `MAX_JOB_ATTEMPTS`.
 * - `complete`: `complete` holds the server's result. Kept until the consumer releases it.
 * - `failed`: terminal, or out of automatic attempts. `retry` may restart it.
 * - `canceled`: the user canceled. `cancelPending` while the server has not confirmed.
 */
export type UploadJobState = "staged" | "uploading" | "finishing" | "paused" | "complete" | "failed" | "canceled"

export type UploadJobMetadata =
  | { kind: "video"; value: UploadVideoMetadata }
  | { kind: "voice"; value: UploadVoiceMetadata }

export type UploadJobFailure = {
  code: string
  message: string
  retryable: boolean
}

export type UploadJobRecord = {
  readonly id: string
  /** Byte store path of the staged source. */
  readonly sourcePath: string
  readonly fileName: string
  readonly mimeType: string
  readonly kind: UploadKind
  readonly byteCount: number
  readonly thumbnailFileUniqueId?: string
  readonly metadata?: UploadJobMetadata
  readonly createdAt: number
  updatedAt: number
  state: UploadJobState
  /** SHA-256 of the source, once hashed. */
  sha256?: Uint8Array
  /** Retry identity: the server deduplicates `CreateUpload` by it within one session. Replaced after a terminal server state. */
  clientUploadId: Uint8Array
  /** How many times the identity was replaced. */
  identityGeneration: number
  /** The server's upload, once a create reply arrived. */
  uploadId?: Uint8Array
  partCount?: number
  /** Parts the server acknowledged. A part's byte offset is `index * PART_SIZE`. */
  acceptedParts: number[]
  /** Server idle expiry, in milliseconds. */
  serverExpiresAt?: number
  /** Completion identity. Persisted before anyone is told. */
  complete?: UploadComplete
  failure?: UploadJobFailure
  /** Automatic attempts used since the last explicit start or retry. */
  attempts: number
  /** Canceled locally, the server not yet told. */
  cancelPending?: boolean
}

/**
 * Durable storage for upload jobs. The replica has no table for them yet (see
 * the README for the recommended schema); the default implementation keeps
 * one small JSON file per job in the media byte store.
 */
export interface MediaJobStore {
  list(): Promise<UploadJobRecord[]>
  get(id: string): Promise<UploadJobRecord | undefined>
  put(job: UploadJobRecord): Promise<void>
  delete(id: string): Promise<void>
  clear(): Promise<void>
}

const copy = (job: UploadJobRecord): UploadJobRecord => decodeRecord<UploadJobRecord>(encodeRecord(job))

export class MemoryMediaJobStore implements MediaJobStore {
  readonly #jobs = new Map<string, string>()

  async list(): Promise<UploadJobRecord[]> {
    return [...this.#jobs.values()].map((text) => decodeRecord<UploadJobRecord>(text))
      .sort((left, right) => left.createdAt - right.createdAt)
  }

  async get(id: string): Promise<UploadJobRecord | undefined> {
    const text = this.#jobs.get(id)
    return text === undefined ? undefined : decodeRecord<UploadJobRecord>(text)
  }

  async put(job: UploadJobRecord): Promise<void> {
    this.#jobs.set(job.id, encodeRecord(job))
  }

  async delete(id: string): Promise<void> {
    this.#jobs.delete(id)
  }

  async clear(): Promise<void> {
    this.#jobs.clear()
  }
}

/** One JSON file per job under `<root>`, each replaced atomically. */
export class ByteStoreJobStore implements MediaJobStore {
  constructor(private readonly store: ByteStore, private readonly root: string) {
    if (!root.endsWith("/")) throw new TypeError("Job store root ends with /")
  }

  #path(id: string): string {
    return `${this.root}${id}.json`
  }

  async list(): Promise<UploadJobRecord[]> {
    const jobs: UploadJobRecord[] = []
    for (const item of await this.store.list(this.root)) {
      if (!item.path.endsWith(".json")) continue
      const bytes = await this.store.read(item.path)
      if (!bytes) continue
      try {
        jobs.push(decodeRecord<UploadJobRecord>(new TextDecoder().decode(bytes)))
      } catch {
        // An unreadable row cannot be resumed; its blob is collected as an orphan.
      }
    }
    return jobs.sort((left, right) => left.createdAt - right.createdAt)
  }

  async get(id: string): Promise<UploadJobRecord | undefined> {
    const bytes = await this.store.read(this.#path(id))
    return bytes ? decodeRecord<UploadJobRecord>(new TextDecoder().decode(bytes)) : undefined
  }

  async put(job: UploadJobRecord): Promise<void> {
    await this.store.write(this.#path(job.id), new TextEncoder().encode(encodeRecord(job)))
  }

  async delete(id: string): Promise<void> {
    await this.store.remove(this.#path(id))
  }

  async clear(): Promise<void> {
    await this.store.removePrefix(this.root)
  }
}

export const cloneJob = copy

export const isJobId = (id: string): boolean => /^[A-Za-z0-9_-]{1,64}$/.test(id)
