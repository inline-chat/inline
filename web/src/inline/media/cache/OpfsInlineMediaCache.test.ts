import { userId } from "@inline/ids"
import { describe, expect, it, vi } from "vitest"
import { OpfsInlineMediaCache } from "./OpfsInlineMediaCache"

class MemoryFileHandle {
  private value = new Blob()
  readonly kind = "file" as const

  async getFile() {
    return this.value as File
  }

  async createWritable() {
    let pending = this.value
    return {
      write: async (value: FileSystemWriteChunkType) => {
        if (!(value instanceof Blob)) {
          throw new Error("Test cache expects Blob writes")
        }
        pending = value
      },
      close: async () => {
        this.value = pending
      },
    } as FileSystemWritableFileStream
  }
}

const fileNameForKey = async (key: string) => {
  const digest = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(key),
  )
  return Array.from(
    new Uint8Array(digest),
    (byte) => byte.toString(16).padStart(2, "0"),
  ).join("")
}

class MemoryDirectoryHandle {
  readonly files = new Map<string, MemoryFileHandle>()
  readonly entries = vi.fn(() => this.iterate())

  private async *iterate() {
    for (const entry of this.files) yield entry
  }

  async getFileHandle(
    name: string,
    options?: FileSystemGetFileOptions,
  ) {
    const existing = this.files.get(name)
    if (existing) return existing
    if (!options?.create) {
      throw new DOMException("Missing", "NotFoundError")
    }
    const created = new MemoryFileHandle()
    this.files.set(name, created)
    return created as unknown as FileSystemFileHandle
  }

  async removeEntry(name: string) {
    if (!this.files.delete(name)) {
      throw new DOMException("Missing", "NotFoundError")
    }
  }
}

describe("OpfsInlineMediaCache", () => {
  it("evicts through indexed metadata without scanning OPFS files", async () => {
    const directory = new MemoryDirectoryHandle()
    let now = 1
    const cache = new OpfsInlineMediaCache({
      accountId: userId(91_001),
      maxBytes: 6,
      directory: Promise.resolve(
        directory as unknown as FileSystemDirectoryHandle,
      ),
      now: () => now++,
    })

    await cache.put("older", new Blob(["1234"]))
    await cache.put("newer", new Blob(["5678"]))

    await expect(cache.get("older")).resolves.toBeUndefined()
    await expect(cache.get("newer")).resolves.toBeDefined()
    expect(directory.entries).toHaveBeenCalledOnce()
  })

  it("uses reads as real LRU touches before the next bounded eviction", async () => {
    const directory = new MemoryDirectoryHandle()
    let now = 1
    const cache = new OpfsInlineMediaCache({
      accountId: userId(91_002),
      maxBytes: 6,
      directory: Promise.resolve(
        directory as unknown as FileSystemDirectoryHandle,
      ),
      now: () => now++,
    })

    await cache.put("first", new Blob(["12"]))
    await cache.put("second", new Blob(["34"]))
    await expect(cache.get("first")).resolves.toBeDefined()
    await cache.put("third", new Blob(["5678"]))

    await expect(cache.get("first")).resolves.toBeDefined()
    await expect(cache.get("second")).resolves.toBeUndefined()
    await expect(cache.get("third")).resolves.toBeDefined()
    expect(directory.entries).toHaveBeenCalledOnce()
  })

  it("reconciles orphaned files into the indexed budget before writing", async () => {
    const directory = new MemoryDirectoryHandle()
    const orphanName = await fileNameForKey("orphan")
    const orphan = await directory.getFileHandle(orphanName, { create: true })
    const writer = await orphan.createWritable()
    await writer.write(new Blob(["1234"]))
    await writer.close()
    const cache = new OpfsInlineMediaCache({
      accountId: userId(91_003),
      maxBytes: 6,
      directory: Promise.resolve(
        directory as unknown as FileSystemDirectoryHandle,
      ),
      now: () => 10,
    })

    await cache.put("new", new Blob(["5678"]))

    await expect(cache.get("orphan")).resolves.toBeUndefined()
    await expect(cache.get("new")).resolves.toBeDefined()
    expect(directory.entries).toHaveBeenCalledOnce()
  })
})
