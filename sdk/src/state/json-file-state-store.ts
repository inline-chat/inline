import { readFile, rename, writeFile } from "node:fs/promises"
import { deserializeStateV1, serializeStateV1 } from "./serde.js"
import type { InlineSdkState, InlineSdkStateStore } from "../sdk/types.js"

export class JsonFileStateStore implements InlineSdkStateStore {
  private readonly path: string

  constructor(path: string) {
    this.path = path
  }

  async load(): Promise<InlineSdkState | null> {
    try {
      const raw = await readFile(this.path, "utf8")
      return deserializeStateV1(raw)
    } catch (error) {
      // File missing or invalid: treat as no state.
      return null
    }
  }

  async save(next: InlineSdkState): Promise<void> {
    const tempPath = `${this.path}.tmp-${Date.now()}-${Math.random().toString(16).slice(2)}`
    const payload = serializeStateV1(next)

    await writeFile(tempPath, payload, "utf8")
    // Best-effort atomic replace on most platforms (write temp in same directory, then rename).
    await rename(tempPath, this.path)
  }
}
