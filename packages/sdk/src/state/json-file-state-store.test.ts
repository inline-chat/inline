import { describe, expect, it } from "vitest"
import { mkdir, mkdtemp, readFile, readdir } from "node:fs/promises"
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

    await store.save({
      version: 1,
      dateCursor: 99n,
      lastSeqByChatId: { "1": 2 },
      lastSeqBySpaceId: { "2": 3 },
      lastUserSeq: 4,
    })

    const raw = await readFile(path, "utf8")
    expect(raw).toContain("\"dateCursor\": \"99\"")

    expect(await store.load()).toEqual({
      version: 1,
      dateCursor: 99n,
      lastSeqByChatId: { "1": 2 },
      lastSeqBySpaceId: { "2": 3 },
      lastUserSeq: 4,
    })
  })

  it("moves invalid json aside and starts fresh", async () => {
    const dir = await mkdtemp(join(tmpdir(), "inline-sdk-state-"))
    const path = join(dir, "state.json")
    await writeFile(path, "{not json", "utf8")
    const store = new JsonFileStateStore(path)
    expect(await store.load()).toBeNull()
    const files = await readdir(dir)
    expect(files).toHaveLength(1)
    expect(files[0]).toMatch(/^state\.json\.invalid-\d+$/)
  })

  it("rejects unreadable state instead of resetting it", async () => {
    const dir = await mkdtemp(join(tmpdir(), "inline-sdk-state-"))
    const path = join(dir, "state.json")
    await mkdir(path)
    const store = new JsonFileStateStore(path)
    await expect(store.load()).rejects.toMatchObject({ code: "EISDIR" })
  })

  it("removes the temp file when the final rename fails", async () => {
    const dir = await mkdtemp(join(tmpdir(), "inline-sdk-state-"))
    const path = join(dir, "state.json")
    await mkdir(path)
    const store = new JsonFileStateStore(path)
    await expect(store.save({ version: 1, lastUserSeq: 1 })).rejects.toThrow()
    expect(await readdir(dir)).toEqual(["state.json"])
  })
})
