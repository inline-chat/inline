import { mkdtemp, readFile, writeFile } from "node:fs/promises"
import os from "node:os"
import path from "node:path"
import { describe, expect, it } from "vitest"
import { AccountStateStore } from "./account-state-store.js"

describe("account-scoped state", () => {
  it("keeps checkpoints across token rotation and rejects another account or API", async () => {
    const directory = await mkdtemp(path.join(os.tmpdir(), "inline-hermes-account-state-"))
    const file = path.join(directory, "state.json")
    const state = { version: 1 as const, lastSeqByChatId: { "23": 17 }, lastUserSeq: 4 }
    await new AccountStateStore(file, "42:first", "https://api.inline.chat").save(state)
    expect(await new AccountStateStore(file, "42:rotated", "https://api.inline.chat/").load()).toEqual(state)
    await expect(new AccountStateStore(file, "43:other", "https://api.inline.chat").load()).rejects.toThrow("another account")
    await expect(new AccountStateStore(file, "42:first", "https://other.inline.chat").load()).rejects.toThrow("API origin")
    await expect(new AccountStateStore(file, "42:first", "https://api.inline.chat/another-api").load()).rejects.toThrow("API origin")
    expect(JSON.parse(await readFile(file, "utf8")).lastSeqByChatId).toEqual({ "23": 17 })
  })

  it("retains an untagged legacy checkpoint and adds ownership on the next write", async () => {
    const directory = await mkdtemp(path.join(os.tmpdir(), "inline-hermes-legacy-state-"))
    const file = path.join(directory, "state.json")
    await writeFile(file, JSON.stringify({ version: 1, lastSeqByChatId: { "23": 17 } }))
    const store = new AccountStateStore(file, "42:current", "https://api.inline.chat")
    const loaded = await store.load()
    expect(loaded?.lastSeqByChatId).toEqual({ "23": 17 })
    await store.save(loaded!)
    expect(JSON.parse(await readFile(file, "utf8")).inlineAccount).toEqual({ botUserId: "42", origin: "https://api.inline.chat" })
  })

  it("does not replace unreadable or malformed state with an empty cursor", async () => {
    const directory = await mkdtemp(path.join(os.tmpdir(), "inline-hermes-invalid-state-"))
    const file = path.join(directory, "state.json")
    await writeFile(file, "invalid")
    await expect(new AccountStateStore(file, "42:current", "https://api.inline.chat").load()).rejects.toThrow()
    expect(await readFile(file, "utf8")).toBe("invalid")
  })

  it("requires a resolved account for writes and validates the authenticated user", async () => {
    const directory = await mkdtemp(path.join(os.tmpdir(), "inline-hermes-unowned-state-"))
    const file = path.join(directory, "state.json")
    const store = new AccountStateStore(file, "unresolved", "https://api.inline.chat")
    expect(await store.load()).toBeNull()
    await expect(store.save({ version: 1 })).rejects.toThrow("account is not resolved")
    store.bindAccount("42")
    await store.save({ version: 1 })
    expect(() => store.bindAccount("43")).toThrow("differs from")
    expect(() => new AccountStateStore(path.join(directory, ".env"), "42:current", "https://api.inline.chat")).toThrow("environment file")
  })
})
