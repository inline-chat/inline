import { describe, expect, it } from "vitest"
import { mkdtemp, readFile } from "node:fs/promises"
import { writeFile } from "node:fs/promises"
import { join } from "node:path"
import { tmpdir } from "node:os"
import { JsonFileStateStore } from "./json-file-state-store.js"

describe("JsonFileStateStore", () => {
  it("returns null when file does not exist", async () => {
    const dir = await mkdtemp(join(tmpdir(), "inline-sdk-state-"))
    const store = new JsonFileStateStore(join(dir, "missing.json"))
    expect(await store.load()).toBeNull()
  })

  it("saves and loads state", async () => {
    const dir = await mkdtemp(join(tmpdir(), "inline-sdk-state-"))
    const path = join(dir, "state.json")
    const store = new JsonFileStateStore(path)

    await store.save({ version: 1, dateCursor: 99n, lastSeqByChatId: { "1": 2 } })

    const raw = await readFile(path, "utf8")
    expect(raw).toContain("\"dateCursor\": \"99\"")

    expect(await store.load()).toEqual({ version: 1, dateCursor: 99n, lastSeqByChatId: { "1": 2 } })
  })

  it("returns null when file is invalid json", async () => {
    const dir = await mkdtemp(join(tmpdir(), "inline-sdk-state-"))
    const path = join(dir, "state.json")
    await writeFile(path, "{not json", "utf8")
    const store = new JsonFileStateStore(path)
    expect(await store.load()).toBeNull()
  })
})
