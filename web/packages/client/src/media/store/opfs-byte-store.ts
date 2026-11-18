import { validatePath, validatePrefix, type ByteStore, type ByteWriter, type StoredItem } from "./byte-store"

/**
 * `ByteStore` over the origin private file system.
 *
 * UNVERIFIED: written against the File System Access and OPFS specifications
 * and never run in a browser. Writes go through `createWritable`, which
 * commits a swap file on `close`; that gives atomic replacement and is where a
 * writer's `checkpoint` comes from. Safari added `createWritable` late; where
 * it is missing this store throws and the core must say media is not being
 * kept. Check in Chromium, Safari and Firefox before relying on it.
 */

type DirectoryEntries = AsyncIterable<[string, FileSystemHandle]>
type MovableFileHandle = FileSystemFileHandle & { move?: (parent: FileSystemDirectoryHandle, name: string) => Promise<void> }

const entriesOf = (directory: FileSystemDirectoryHandle): DirectoryEntries =>
  (directory as unknown as { entries(): DirectoryEntries }).entries()

const isNotFound = (error: unknown): boolean =>
  error instanceof DOMException && (error.name === "NotFoundError" || error.name === "TypeMismatchError")

export class OpfsByteStore implements ByteStore {
  constructor(
    private readonly root: () => Promise<FileSystemDirectoryHandle> = () => navigator.storage.getDirectory(),
  ) {}

  async #directory(segments: readonly string[], create: boolean): Promise<FileSystemDirectoryHandle | undefined> {
    let directory = await this.root()
    for (const segment of segments) {
      try {
        directory = await directory.getDirectoryHandle(segment, { create })
      } catch (error) {
        if (!create && isNotFound(error)) return undefined
        throw error
      }
    }
    return directory
  }

  async #file(path: string, create: boolean): Promise<{ parent: FileSystemDirectoryHandle; handle: FileSystemFileHandle; name: string } | undefined> {
    const segments = validatePath(path)
    const name = segments.at(-1)!
    const parent = await this.#directory(segments.slice(0, -1), create)
    if (!parent) return undefined
    try {
      return { parent, handle: await parent.getFileHandle(name, { create }), name }
    } catch (error) {
      if (!create && isNotFound(error)) return undefined
      throw error
    }
  }

  async write(path: string, data: Blob | Uint8Array): Promise<void> {
    const file = await this.#file(path, true)
    const writable = await file!.handle.createWritable({ keepExistingData: false })
    try {
      await writable.write(data instanceof Uint8Array ? new Blob([data as Uint8Array<ArrayBuffer>]) : data)
      await writable.close()
    } catch (error) {
      await writable.abort().catch(() => {})
      throw error
    }
  }

  async read(path: string, offset = 0, length?: number): Promise<Uint8Array | undefined> {
    const blob = await this.blob(path)
    if (!blob) return undefined
    const end = length === undefined ? blob.size : Math.min(blob.size, offset + length)
    return new Uint8Array(await blob.slice(offset, end).arrayBuffer())
  }

  async blob(path: string): Promise<Blob | undefined> {
    const file = await this.#file(path, false)
    return file ? await file.handle.getFile() : undefined
  }

  async stat(path: string): Promise<StoredItem | undefined> {
    const blob = (await this.blob(path)) as File | undefined
    return blob ? { path, size: blob.size, modifiedAt: blob.lastModified } : undefined
  }

  async list(prefix: string): Promise<StoredItem[]> {
    const directory = await this.#directory(validatePrefix(prefix), false)
    if (!directory) return []
    const out: StoredItem[] = []
    const walk = async (current: FileSystemDirectoryHandle, base: string): Promise<void> => {
      for await (const [name, handle] of entriesOf(current)) {
        if (handle.kind === "directory") {
          await walk(handle as FileSystemDirectoryHandle, `${base}${name}/`)
        } else {
          const file = await (handle as FileSystemFileHandle).getFile()
          out.push({ path: `${base}${name}`, size: file.size, modifiedAt: file.lastModified })
        }
      }
    }
    await walk(directory, prefix)
    return out.sort((left, right) => (left.path < right.path ? -1 : 1))
  }

  async openWriter(path: string, options: { truncateTo?: number } = {}): Promise<ByteWriter> {
    const file = (await this.#file(path, true))!
    let committed = (await file.handle.getFile()).size
    if (options.truncateTo !== undefined && options.truncateTo < committed) committed = options.truncateTo
    let writable: FileSystemWritableFileStream | undefined
    let written = 0
    let open = true
    const ensure = async () => {
      if (!open) throw new Error("Writer is closed")
      if (!writable) {
        writable = await file.handle.createWritable({ keepExistingData: true })
        await writable.truncate(committed)
        await writable.seek(committed)
      }
      return writable
    }
    const checkpoint = async () => {
      if (!open) throw new Error("Writer is closed")
      if (!writable) return
      await writable.close()
      writable = undefined
      committed += written
      written = 0
    }
    if (options.truncateTo !== undefined) {
      await ensure()
      await checkpoint()
    }
    return {
      get size() {
        return committed + written
      },
      async write(chunk) {
        const stream = await ensure()
        await stream.write(new Blob([chunk as Uint8Array<ArrayBuffer>]))
        written += chunk.length
      },
      checkpoint,
      async close() {
        await checkpoint()
        open = false
      },
      async abort() {
        open = false
        await writable?.abort().catch(() => {})
        writable = undefined
      },
    }
  }

  async rename(from: string, to: string): Promise<void> {
    const source = await this.#file(from, false)
    if (!source) throw new Error(`No file at ${from}`)
    const segments = validatePath(to)
    const parent = (await this.#directory(segments.slice(0, -1), true))!
    const movable = source.handle as MovableFileHandle
    if (typeof movable.move === "function") {
      await movable.move(parent, segments.at(-1)!)
      return
    }
    await this.write(to, await source.handle.getFile())
    await source.parent.removeEntry(source.name)
  }

  async remove(path: string): Promise<void> {
    const segments = validatePath(path)
    const parent = await this.#directory(segments.slice(0, -1), false)
    try {
      await parent?.removeEntry(segments.at(-1)!)
    } catch (error) {
      if (!isNotFound(error)) throw error
    }
  }

  async removePrefix(prefix: string): Promise<void> {
    const segments = validatePrefix(prefix)
    const parent = await this.#directory(segments.slice(0, -1), false)
    try {
      await parent?.removeEntry(segments.at(-1)!, { recursive: true })
    } catch (error) {
      if (!isNotFound(error)) throw error
    }
  }
}
