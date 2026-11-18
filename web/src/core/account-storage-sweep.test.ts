import { describe, expect, it } from "vitest"
import type { UserID } from "@inline/ids"
import {
  ERASE_MARKER_NAME,
  ownersFromAuthState,
  sweepAccountStorage,
  type AccountStorageSweepOptions,
  type SweepFileSystem,
} from "./account-storage-sweep"

const NS = "api.inline.chat"
const pool = (userId: string, namespace = NS) => `.inline-sqlite-v2/${namespace}/user-${userId}`
const uid = (n: number) => String(n) as UserID

/** A file system of paths: directories and files, with an optional failure on one removal. */
class MemoryFs implements SweepFileSystem {
  readonly entries = new Map<string, "dir" | "file">()
  failRemove: string | undefined

  add(path: string, kind: "dir" | "file" = "file") {
    const parts = path.split("/")
    for (let i = 1; i < parts.length; i++) this.entries.set(parts.slice(0, i).join("/"), "dir")
    this.entries.set(path, kind)
  }

  has(path: string) {
    return this.entries.has(path)
  }

  async directories(path: readonly string[]) {
    const prefix = `${path.join("/")}/`
    return [...this.entries]
      .filter(([key, kind]) => kind === "dir" && key.startsWith(prefix) && !key.slice(prefix.length).includes("/"))
      .map(([key]) => key.slice(prefix.length))
  }

  async fileExists(path: readonly string[]) {
    return this.entries.get(path.join("/")) === "file"
  }

  async writeFile(path: readonly string[], _text: string) {
    this.add(path.join("/"))
  }

  async remove(path: readonly string[]) {
    const key = path.join("/")
    if (this.failRemove === key) throw Object.assign(new Error("busy"), { name: "NoModificationAllowedError" })
    for (const entry of this.entries.keys()) if (entry === key || entry.startsWith(`${key}/`)) this.entries.delete(entry)
  }
}

const setup = (owners: readonly number[] | null) => {
  const fs = new MemoryFs()
  const held = new Set<string>()
  const lockedDuringRemoval: string[] = []
  let ownerSet: Set<UserID> | undefined = owners ? new Set(owners.map(uid)) : undefined
  const options: AccountStorageSweepOptions = {
    fs,
    poolDirectory: (userId) => pool(userId),
    owners: () => ownerSet,
    tryLockAccount: async (userId) => {
      if (held.has(userId)) return null
      held.add(userId)
      lockedDuringRemoval.push(userId)
      return { release: () => void held.delete(userId) }
    },
    now: () => 1,
  }
  return {
    fs,
    held,
    options,
    setOwners: (next: readonly number[] | undefined) => {
      ownerSet = next ? new Set(next.map(uid)) : undefined
    },
    sweep: (extra: Partial<AccountStorageSweepOptions> = {}) => sweepAccountStorage({ ...options, ...extra }),
  }
}

/** One account's full storage: its pool and media. */
const account = (fs: MemoryFs, userId: string, options: { marker?: boolean; namespace?: string } = {}) => {
  fs.add(`${pool(userId, options.namespace)}/.opaque/abc`)
  fs.add(`accounts/u${userId}/media/cache/1`)
  if (options.marker) fs.add(`accounts/u${userId}/${ERASE_MARKER_NAME}`)
}

describe("sweepAccountStorage", () => {
  it("removes the pool and media of an account nobody is signed in to, and keeps the signed-in one", async () => {
    const s = setup([1])
    account(s.fs, "1")
    account(s.fs, "2")
    const report = await s.sweep()
    expect(report).toEqual({ removed: [uid(2)], skipped: [{ userId: uid(1), reason: "owned" }] })
    expect(s.fs.has(pool("2"))).toBe(false)
    expect(s.fs.has("accounts/u2")).toBe(false)
    expect(s.fs.has(`${pool("1")}/.opaque/abc`)).toBe(true)
    expect(s.fs.has("accounts/u1/media/cache/1")).toBe(true)
    expect(s.held.size).toBe(0)
  })

  it("treats every owner as owned (multi-account), including one awaiting re-authentication", async () => {
    const s = setup([1, 2])
    account(s.fs, "1")
    account(s.fs, "2", { marker: true })
    expect((await s.sweep()).removed).toEqual([])
    expect(s.fs.has(`${pool("2")}/.opaque/abc`)).toBe(true)
  })

  it("removes nothing while the owners are unknown", async () => {
    const s = setup(null)
    account(s.fs, "2")
    expect(await s.sweep()).toEqual({ removed: [], skipped: [], stopped: "ownersUnknown" })
    expect(s.fs.has(`${pool("2")}/.opaque/abc`)).toBe(true)
  })

  it("skips an account whose leader lock is held: a core may have its storage open", async () => {
    const s = setup([])
    account(s.fs, "2")
    s.held.add("2")
    expect((await s.sweep()).skipped).toEqual([{ userId: uid(2), reason: "busy" }])
    expect(s.fs.has(`${pool("2")}/.opaque/abc`)).toBe(true)
    expect(s.fs.has("accounts/u2/media/cache/1")).toBe(true)
  })

  it("reads the owners again under the lock: a sign-in that landed meanwhile keeps its storage", async () => {
    const s = setup([])
    account(s.fs, "2")
    const report = await s.sweep({
      tryLockAccount: async () => {
        s.setOwners([2])
        return { release: () => {} }
      },
    })
    expect(report.skipped).toEqual([{ userId: uid(2), reason: "owned" }])
    expect(s.fs.has(`${pool("2")}/.opaque/abc`)).toBe(true)
  })

  it("leaves media that is not this namespace's (no pool here, no erase marker)", async () => {
    const s = setup([])
    account(s.fs, "3", { namespace: "demo-x" })
    expect((await s.sweep()).removed).toEqual([])
    expect(s.fs.has("accounts/u3/media/cache/1")).toBe(true)
    expect(s.fs.has(`${pool("3", "demo-x")}/.opaque/abc`)).toBe(true)
  })

  it("finishes an erase a killed core left: marker and media without a pool", async () => {
    const s = setup([])
    s.fs.add("accounts/u4/media/cache/1")
    s.fs.add(`accounts/u4/${ERASE_MARKER_NAME}`)
    expect((await s.sweep()).removed).toEqual([uid(4)])
    expect(s.fs.has("accounts/u4")).toBe(false)
  })

  it("is safe to interrupt: a failed removal keeps the marker, and the next sweep finishes", async () => {
    const s = setup([])
    account(s.fs, "5")
    s.fs.failRemove = pool("5")
    expect((await s.sweep()).skipped).toEqual([{ userId: uid(5), reason: "failed" }])
    expect(s.fs.has(`accounts/u5/${ERASE_MARKER_NAME}`)).toBe(true)
    expect(s.held.size).toBe(0)

    s.fs.failRemove = undefined
    expect((await s.sweep()).removed).toEqual([uid(5)])
    expect([...s.fs.entries.keys()].filter((key) => key.includes("5"))).toEqual([])
  })

  it("ignores names this build does not write", async () => {
    const s = setup([])
    s.fs.add(`.inline-sqlite-v2/${NS}/user-abc/x`)
    s.fs.add("accounts/other/x")
    expect(await s.sweep()).toEqual({ removed: [], skipped: [] })
    expect(s.fs.has(`.inline-sqlite-v2/${NS}/user-abc/x`)).toBe(true)
  })

  it("yields between accounts", async () => {
    const s = setup([])
    account(s.fs, "6")
    account(s.fs, "7")
    let pauses = 0
    await s.sweep({
      pause: async () => {
        pauses += 1
      },
    })
    expect(pauses).toBe(2)
  })
})

describe("ownersFromAuthState", () => {
  const state = (extra: Partial<Parameters<typeof ownersFromAuthState>[0]>) => ({
    hasHydrated: true,
    storageStatus: "ready",
    currentUserId: null,
    userIdHint: null,
    ...extra,
  })

  it("is unknown until the stored session was read and is reliable", () => {
    expect(ownersFromAuthState(state({ hasHydrated: false }))).toBeUndefined()
    expect(ownersFromAuthState(state({ storageStatus: "hydrating" }))).toBeUndefined()
    expect(ownersFromAuthState(state({ storageStatus: "unavailable" }))).toBeUndefined()
    expect(ownersFromAuthState(state({ storageStatus: "corrupt", userIdHint: uid(1) }))).toBeUndefined()
  })

  it("lists the signed-in user and the hinted one", () => {
    expect([...ownersFromAuthState(state({ currentUserId: uid(1), userIdHint: uid(1) }))!]).toEqual([uid(1)])
    expect([...ownersFromAuthState(state({ userIdHint: uid(2) }))!]).toEqual([uid(2)])
    expect(ownersFromAuthState(state({}))!.size).toBe(0)
  })
})
