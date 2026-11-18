import { systemClock, type MediaClock } from "../types"

/**
 * Where media bytes live, outside SQLite: OPFS in the browser, memory in
 * tests. Paths are `/`-separated relative paths of plain segments; a prefix
 * names a directory and ends with `/`.
 */
export type StoredItem = {
  readonly path: string
  readonly size: number
  /** Last write, in clock milliseconds. */
  readonly modifiedAt: number
}

export interface ByteWriter {
  /** Bytes in the file: what was durable when it opened, plus everything written since. */
  readonly size: number
  /** Appends at `size`. */
  write(chunk: Uint8Array): Promise<void>
  /** Makes every byte written so far durable. */
  checkpoint(): Promise<void>
  /** Checkpoints and releases the file. */
  close(): Promise<void>
  /** Drops bytes written since the last checkpoint and releases the file. */
  abort(): Promise<void>
}

export interface ByteStore {
  /** Replaces the file atomically: a reader sees the old bytes or all of the new ones. */
  write(path: string, data: Blob | Uint8Array): Promise<void>
  read(path: string, offset?: number, length?: number): Promise<Uint8Array | undefined>
  /** The file as a `Blob`, for an object URL or a `slice`-based reader. */
  blob(path: string): Promise<Blob | undefined>
  stat(path: string): Promise<StoredItem | undefined>
  /** Every file under the prefix, recursively. */
  list(prefix: string): Promise<StoredItem[]>
  /** Opens for appending. `truncateTo` drops bytes past that length first. */
  openWriter(path: string, options?: { truncateTo?: number }): Promise<ByteWriter>
  rename(from: string, to: string): Promise<void>
  remove(path: string): Promise<void>
  removePrefix(prefix: string): Promise<void>
}

const SEGMENT = /^[A-Za-z0-9._~-]+$/

export const validatePath = (path: string): string[] => {
  const segments = path.split("/")
  if (segments.length === 0 || segments.some((segment) => !SEGMENT.test(segment) || segment === "." || segment === "..")) {
    throw new TypeError(`Invalid media store path: ${path}`)
  }
  return segments
}

export const validatePrefix = (prefix: string): string[] => {
  if (!prefix.endsWith("/")) throw new TypeError(`A prefix ends with "/": ${prefix}`)
  return validatePath(prefix.slice(0, -1))
}

const concat = (chunks: readonly Uint8Array[]): Uint8Array => {
  let length = 0
  for (const chunk of chunks) length += chunk.length
  const out = new Uint8Array(length)
  let offset = 0
  for (const chunk of chunks) {
    out.set(chunk, offset)
    offset += chunk.length
  }
  return out
}

type MemoryFile = { bytes: Uint8Array; modifiedAt: number }

/**
 * The reference store. Writers buffer until `checkpoint`, like OPFS writable
 * streams, so `dropUncommitted()` simulates a process that died between
 * checkpoints.
 */
export class MemoryByteStore implements ByteStore {
  readonly #files = new Map<string, MemoryFile>()
  readonly #writers = new Set<{ path: string; drop: () => void }>()
  #failNextWrite: Error | undefined

  constructor(private readonly clock: MediaClock = systemClock) {}

  /** Test hook: the next write or checkpoint throws (quota exceeded, for example). */
  failNextWrite(error: Error = new DOMException("Quota exceeded", "QuotaExceededError")): void {
    this.#failNextWrite = error
  }

  /** Test hook: forget every writer's uncheckpointed bytes, as a crash would. */
  dropUncommitted(): void {
    for (const writer of this.#writers) writer.drop()
    this.#writers.clear()
  }

  /** Test hook: the total bytes held. */
  get totalBytes(): number {
    let total = 0
    for (const file of this.#files.values()) total += file.bytes.length
    return total
  }

  /** Test hook: set a file's modification time. */
  touch(path: string, modifiedAt: number): void {
    const file = this.#files.get(path)
    if (file) file.modifiedAt = modifiedAt
  }

  #takeFailure(): void {
    const error = this.#failNextWrite
    if (error) {
      this.#failNextWrite = undefined
      throw error
    }
  }

  async write(path: string, data: Blob | Uint8Array): Promise<void> {
    validatePath(path)
    const bytes = data instanceof Uint8Array ? data.slice() : new Uint8Array(await data.arrayBuffer())
    this.#takeFailure()
    this.#files.set(path, { bytes, modifiedAt: this.clock.now() })
  }

  async read(path: string, offset = 0, length?: number): Promise<Uint8Array | undefined> {
    validatePath(path)
    const file = this.#files.get(path)
    if (!file) return undefined
    const end = length === undefined ? file.bytes.length : Math.min(file.bytes.length, offset + length)
    return file.bytes.slice(offset, end)
  }

  async blob(path: string): Promise<Blob | undefined> {
    const bytes = await this.read(path)
    return bytes ? new Blob([bytes as Uint8Array<ArrayBuffer>]) : undefined
  }

  async stat(path: string): Promise<StoredItem | undefined> {
    validatePath(path)
    const file = this.#files.get(path)
    return file ? { path, size: file.bytes.length, modifiedAt: file.modifiedAt } : undefined
  }

  async list(prefix: string): Promise<StoredItem[]> {
    validatePrefix(prefix)
    const out: StoredItem[] = []
    for (const [path, file] of this.#files) {
      if (path.startsWith(prefix)) out.push({ path, size: file.bytes.length, modifiedAt: file.modifiedAt })
    }
    return out.sort((left, right) => (left.path < right.path ? -1 : 1))
  }

  async openWriter(path: string, options: { truncateTo?: number } = {}): Promise<ByteWriter> {
    validatePath(path)
    const existing = this.#files.get(path)?.bytes ?? new Uint8Array()
    let committed = options.truncateTo === undefined ? existing : existing.slice(0, options.truncateTo)
    if (committed !== existing || !this.#files.has(path)) {
      this.#files.set(path, { bytes: committed, modifiedAt: this.clock.now() })
    }
    let pending: Uint8Array[] = []
    let pendingLength = 0
    let open = true
    const handle = {
      path,
      drop: () => {
        pending = []
        pendingLength = 0
        open = false
      },
    }
    this.#writers.add(handle)
    const requireOpen = () => {
      if (!open) throw new Error("Writer is closed")
    }
    const checkpoint = async () => {
      requireOpen()
      this.#takeFailure()
      if (pendingLength > 0) {
        committed = concat([committed, ...pending])
        pending = []
        pendingLength = 0
      }
      this.#files.set(path, { bytes: committed, modifiedAt: this.clock.now() })
    }
    return {
      get size() {
        return committed.length + pendingLength
      },
      write: async (chunk) => {
        requireOpen()
        pending.push(chunk.slice())
        pendingLength += chunk.length
      },
      checkpoint,
      close: async () => {
        await checkpoint()
        open = false
        this.#writers.delete(handle)
      },
      abort: async () => {
        handle.drop()
        this.#writers.delete(handle)
      },
    }
  }

  async rename(from: string, to: string): Promise<void> {
    validatePath(from)
    validatePath(to)
    const file = this.#files.get(from)
    if (!file) throw new Error(`No file at ${from}`)
    this.#files.delete(from)
    this.#files.set(to, file)
  }

  async remove(path: string): Promise<void> {
    validatePath(path)
    this.#dropWriters((candidate) => candidate === path)
    this.#files.delete(path)
  }

  async removePrefix(prefix: string): Promise<void> {
    validatePrefix(prefix)
    this.#dropWriters((candidate) => candidate.startsWith(prefix))
    for (const path of Array.from(this.#files.keys())) if (path.startsWith(prefix)) this.#files.delete(path)
  }

  /** A removed file's open writer is closed, so it cannot write the file back. */
  #dropWriters(matches: (path: string) => boolean): void {
    for (const writer of Array.from(this.#writers)) {
      if (!matches(writer.path)) continue
      writer.drop()
      this.#writers.delete(writer)
    }
  }
}

/** Reads a stored file in bounded chunks. */
export async function* readChunks(
  store: ByteStore,
  path: string,
  size: number,
  chunkSize: number,
  signal?: AbortSignal,
): AsyncGenerator<Uint8Array> {
  for (let offset = 0; offset < size; offset += chunkSize) {
    if (signal?.aborted) return
    const length = Math.min(chunkSize, size - offset)
    const bytes = await store.read(path, offset, length)
    if (!bytes || bytes.length !== length) throw new Error("Stored file changed while it was read")
    yield bytes
  }
}
