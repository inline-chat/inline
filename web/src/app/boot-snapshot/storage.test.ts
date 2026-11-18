import { describe, expect, it } from "vitest"
import { memoryStorage } from "../test-fixtures"
import { BOOT_SNAPSHOT_FORMAT, BOOT_SNAPSHOT_KEY, BOOT_SNAPSHOT_VERSION, type BootSnapshot } from "./format"
import { eraseBootSnapshot, readBootSnapshot, writeBootSnapshot } from "./storage"
import { BUILD, dialog, uid } from "./test-support"

const client = {
  format: 1,
  queries: [{ sub: 2, query: { kind: "sidebar", mode: "inbox" } }],
  store: { format: 1, revision: 4, lists: [{ sub: 2, keys: ["dialog:1"] as unknown[] }], rows: [dialog(1)] as unknown[] },
}

const snapshot = (extra: Partial<Record<keyof BootSnapshot, unknown>> = {}) => ({
  format: BOOT_SNAPSHOT_FORMAT,
  version: BOOT_SNAPSHOT_VERSION,
  build: BUILD,
  user: uid(7),
  savedAt: 1,
  client,
  ...extra,
})

const stored = (value: unknown) => {
  const local = memoryStorage()
  local.setItem(BOOT_SNAPSHOT_KEY, typeof value === "string" ? value : JSON.stringify(value))
  return local
}

describe("reading the boot snapshot", () => {
  it("reads a snapshot written by this build", () => {
    const local = stored(snapshot())
    const read = readBootSnapshot(local, { buildId: BUILD })
    expect(read.kind).toBe("snapshot")
    if (read.kind === "snapshot") expect(read.snapshot.user).toBe(uid(7))
    expect(local.getItem(BOOT_SNAPSHOT_KEY)).not.toBeNull()
  })

  it.each([
    ["damaged JSON", "{\"format\": \"inline.boot-snap", "damaged"],
    ["someone else's value", { hello: 1 }, "damaged"],
    ["another schema version", snapshot({ version: BOOT_SNAPSHOT_VERSION + 1 }), "version"],
    ["another build", snapshot({ build: "2026-11-16T00:00:00.000Z" }), "build"],
    ["a user ID that is not one", snapshot({ user: 7 }), "damaged"],
    ["a row without a kind", snapshot({ client: { ...client, store: { ...client.store, rows: [{ id: "1" }] } } }), "damaged"],
    ["a list that is not keys", snapshot({ client: { ...client, store: { ...client.store, lists: [{ sub: 2, keys: [3] }] } } }), "damaged"],
  ])("ignores and removes %s, without throwing", (_name, value, reason) => {
    const local = stored(value)
    expect(readBootSnapshot(local, { buildId: BUILD })).toEqual({ kind: "discarded", reason })
    expect(local.getItem(BOOT_SNAPSHOT_KEY)).toBeNull()
    expect(readBootSnapshot(local, { buildId: BUILD })).toEqual({ kind: "none" })
  })

  it("erases it unread when a sign-out has not finished", () => {
    const local = stored(snapshot())
    expect(readBootSnapshot(local, { buildId: BUILD, signedOut: () => true })).toEqual({ kind: "discarded", reason: "signedOut" })
    expect(local.getItem(BOOT_SNAPSHOT_KEY)).toBeNull()
  })

  it("treats missing or throwing storage as empty", () => {
    expect(readBootSnapshot(undefined, { buildId: BUILD })).toEqual({ kind: "none" })
    const blocked = {
      getItem: () => {
        throw new Error("SecurityError")
      },
      setItem: () => {
        throw new Error("QuotaExceededError")
      },
      removeItem: () => {
        throw new Error("SecurityError")
      },
    }
    expect(readBootSnapshot(blocked, { buildId: BUILD })).toEqual({ kind: "none" })
    expect(writeBootSnapshot(blocked, "{}")).toBe(false)
    expect(() => eraseBootSnapshot(blocked)).not.toThrow()
  })

  it("leaves nothing stale when a write is refused", () => {
    const local = stored(snapshot())
    const full = { ...local, setItem: () => {
      throw new Error("QuotaExceededError")
    } }
    expect(writeBootSnapshot(full, JSON.stringify(snapshot({ savedAt: 2 })))).toBe(false)
    expect(local.getItem(BOOT_SNAPSHOT_KEY)).toBeNull()
  })
})
