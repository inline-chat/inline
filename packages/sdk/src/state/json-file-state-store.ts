import { readFile, rename, rm, writeFile } from "node:fs/promises"
import { deserializeStateV1, serializeStateV1 } from "./serde.js"
import type { InlineSdkState, InlineSdkStateStore } from "../sdk/types.js"

export class JsonFileStateStore implements InlineSdkStateStore {
  private readonly path: string

  constructor(path: string) {
    this.path = path
  }

  async load(): Promise<InlineSdkState | null> {
    let raw: string
    try {
      raw = await readFile(this.path, "utf8")
    } catch (error) {
      // Only a missing file means "no state yet". Anything else (permissions, a
      // directory in the way) must not silently reset the sync cursors.
      if ((error as NodeJS.ErrnoException | null)?.code === "ENOENT") return null
      throw error
    }
    try {
      return deserializeStateV1(raw)
    } catch {
      // A corrupt file cannot be resumed from, and throwing would keep an
      // unattended bot from ever reconnecting. Keep it for inspection and start
      // fresh, as the store did before it could tell the cases apart.
      await rename(this.path, `${this.path}.invalid-${Date.now()}`).catch(() => {})
      return null
    }
  }

  async save(next: InlineSdkState): Promise<void> {
    const tempPath = `${this.path}.tmp-${Date.now()}-${Math.random().toString(16).slice(2)}`
    const payload = serializeStateV1(next)

    try {
      await writeFile(tempPath, payload, "utf8")
      // Best-effort atomic replace on most platforms (write temp in same directory, then rename).
      await rename(tempPath, this.path)
    } catch (error) {
      await rm(tempPath, { force: true }).catch(() => {})
      throw error
    }
  }
}
