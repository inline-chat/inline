/// <reference lib="webworker" />
/**
 * Where the demo's simulated server keeps its state across reloads: one JSON
 * file per demo in OPFS (`inline-demo/<namespace>.json`), beside but apart
 * from the replica's SQLite pool. Written whole, through a writable stream
 * where the browser has one (atomic on close), else a sync access handle.
 */
import type { DemoWorldStore } from "../../../packages/client/src/testing/demo-world"

const DIRECTORY = "inline-demo"

const isNotFound = (error: unknown) =>
  error instanceof DOMException && (error.name === "NotFoundError" || error.name === "TypeMismatchError")

export const opfsWorldStore = (namespace: string): DemoWorldStore => {
  const fileName = `${namespace.replace(/[^\w.-]/g, "_")}.json`
  const directory = async () =>
    (await navigator.storage.getDirectory()).getDirectoryHandle(DIRECTORY, { create: true })

  return {
    kind: "opfs",
    async load() {
      let file: File
      try {
        file = await (await (await directory()).getFileHandle(fileName)).getFile()
      } catch (error) {
        if (isNotFound(error)) return undefined
        throw error
      }
      const text = await file.text()
      if (text.length === 0) return undefined
      try {
        return JSON.parse(text) as unknown
      } catch {
        // An interrupted write: treated as no saved state (the server then
        // assumes an unknown past, which is safe).
        return undefined
      }
    },
    async save(state) {
      const handle = await (await directory()).getFileHandle(fileName, { create: true })
      const json = JSON.stringify(state)
      if ("createWritable" in handle && typeof handle.createWritable === "function") {
        const writable = await handle.createWritable()
        await writable.write(json)
        await writable.close()
        return
      }
      const access = await handle.createSyncAccessHandle()
      try {
        const bytes = new TextEncoder().encode(json)
        access.truncate(0)
        access.write(bytes, { at: 0 })
        access.flush()
      } finally {
        access.close()
      }
    },
    async erase() {
      try {
        await (await directory()).removeEntry(fileName)
      } catch (error) {
        if (!isNotFound(error)) throw error
      }
    },
  }
}
