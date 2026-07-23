import {
  defaultInlineMediaCacheBytes,
  type InlineMediaCache,
  type InlineMediaCacheOptions,
} from "./InlineMediaCache"
import type { UserID } from "@inline/ids"
import { IndexedDbInlineMediaMetadata } from "./IndexedDbInlineMediaMetadata"

type StorageManagerWithOpfs = StorageManager & {
  getDirectory(): Promise<FileSystemDirectoryHandle>
}

const fileNameForKey = async (key: string) => {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(key))
  return Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, "0")).join("")
}

type InlineMediaMetadata = Pick<
  IndexedDbInlineMediaMetadata,
  "get" | "record" | "remove" | "totalBytes" | "oldest" | "all"
>

export type OpfsInlineMediaCacheOptions =
  InlineMediaCacheOptions & {
    directory?: Promise<FileSystemDirectoryHandle>
    metadata?: InlineMediaMetadata
    now?: () => number
  }

export class OpfsInlineMediaCache implements InlineMediaCache {
  private readonly maxBytes: number
  private readonly directory: Promise<FileSystemDirectoryHandle>
  private readonly metadata: InlineMediaMetadata
  private readonly now: () => number
  private mutationTail = Promise.resolve()
  private reconciliationTask: Promise<void> | undefined

  constructor({
    accountId,
    maxBytes = defaultInlineMediaCacheBytes,
    directory,
    metadata,
    now = Date.now,
  }: OpfsInlineMediaCacheOptions) {
    this.maxBytes = maxBytes
    this.directory = directory ?? this.openDirectory(accountId)
    this.metadata =
      metadata ??
      new IndexedDbInlineMediaMetadata(String(accountId))
    this.now = now
  }

  async get(key: string) {
    const fileName = await fileNameForKey(key)
    try {
      const directory = await this.directory
      const handle = await directory.getFileHandle(fileName)
      const file = await handle.getFile()
      await this.metadata
        .record({
          fileName,
          size: file.size,
          lastAccessedAt: this.now(),
        })
        .catch(() => undefined)
      return file
    } catch (cause) {
      if (
        cause instanceof DOMException &&
        cause.name === "NotFoundError"
      ) {
        await this.metadata.remove(fileName).catch(() => undefined)
        return undefined
      }
      throw cause
    }
  }

  async put(key: string, blob: Blob) {
    if (blob.size > this.maxBytes) return
    return await this.mutate(async () => {
      await this.ensureReconciled()
      const directory = await this.directory
      const fileName = await fileNameForKey(key)
      const previous = await this.metadata.get(fileName)
      await this.evictTo(
        Math.max(
          0,
          this.maxBytes - blob.size + (previous?.size ?? 0),
        ),
        fileName,
      )
      try {
        await this.write(directory, fileName, blob)
      } catch (cause) {
        if (!this.isQuotaError(cause)) throw cause
        await this.evictTo(0, fileName)
        await this.write(directory, fileName, blob)
      }
      await this.metadata.record({
        fileName,
        size: blob.size,
        lastAccessedAt: this.now(),
      })
    })
  }

  private async write(
    directory: FileSystemDirectoryHandle,
    fileName: string,
    blob: Blob,
  ) {
    const handle = await directory.getFileHandle(fileName, {
      create: true,
    })
    const writer = await handle.createWritable()
    await writer.write(blob)
    await writer.close()
  }

  private async openDirectory(accountId: UserID) {
    const storage = navigator.storage as StorageManagerWithOpfs
    const root = await storage.getDirectory()
    const media = await root.getDirectoryHandle("inline-media", { create: true })
    return await media.getDirectoryHandle(`account-${accountId}`, { create: true })
  }

  private async evictTo(targetBytes: number, excludedFileName: string) {
    const directory = await this.directory
    let totalBytes = await this.metadata.totalBytes()
    while (totalBytes > targetBytes) {
      const oldest = (
        await this.metadata.oldest(16)
      ).filter((entry) => entry.fileName !== excludedFileName)
      if (oldest.length === 0) return
      for (const entry of oldest) {
        try {
          await directory.removeEntry(entry.fileName)
        } catch (cause) {
          if (!this.isNotFoundError(cause)) throw cause
        }
        await this.metadata.remove(entry.fileName)
        totalBytes = Math.max(0, totalBytes - entry.size)
        if (totalBytes <= targetBytes) return
      }
    }
  }

  /** Repairs file/index drift once before the first mutation. Reads stay on
   * the direct hashed path and never wait for a directory-wide scan. */
  private ensureReconciled() {
    if (!this.reconciliationTask) {
      this.reconciliationTask = this.reconcile()
    }
    return this.reconciliationTask
  }

  private async reconcile() {
    const directory = await this.directory
    const seen = new Set<string>()
    for await (const [fileName, handle] of directory.entries()) {
      if (handle.kind !== "file") continue
      seen.add(fileName)
      const file = await handle.getFile()
      const existing = await this.metadata.get(fileName)
      if (!existing || existing.size !== file.size) {
        await this.metadata.record({
          fileName,
          size: file.size,
          lastAccessedAt:
            existing?.lastAccessedAt ??
            (file.lastModified || this.now()),
        })
      }
    }
    for (const entry of await this.metadata.all()) {
      if (!seen.has(entry.fileName)) {
        await this.metadata.remove(entry.fileName)
      }
    }
  }

  private mutate<T>(operation: () => Promise<T>) {
    const result = this.mutationTail.then(operation, operation)
    this.mutationTail = result.then(
      () => undefined,
      () => undefined,
    )
    return result
  }

  private isNotFoundError(cause: unknown) {
    return cause instanceof DOMException && cause.name === "NotFoundError"
  }

  private isQuotaError(cause: unknown) {
    return cause instanceof DOMException && cause.name === "QuotaExceededError"
  }
}
