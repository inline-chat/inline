import { beforeEach, describe, expect, mock, test } from "bun:test"

const values = new Map<string, string>()
let failWrite: string | undefined
let failDelete: string | undefined
let failRead: string | undefined
let readHook: ((key: string) => Promise<void>) | undefined
mock.module("expo-crypto", () => ({ randomUUID: () => "test-device" }))
mock.module("expo-secure-store", () => ({
  getItemAsync: async (key: string) => {
    if (key === failRead) throw new Error("Secure storage unavailable")
    const value = values.get(key) ?? null
    await readHook?.(key)
    return value
  },
  setItemAsync: async (key: string, value: string) => {
    if (key === failWrite) throw new Error("Secure storage unavailable")
    values.set(key, value)
  },
  deleteItemAsync: async (key: string) => {
    if (key === failDelete) throw new Error("Secure storage unavailable")
    values.delete(key)
  },
}))

const { loadSession, saveSession, clearSession } = await import("../src/auth/session")

beforeEach(() => {
  values.clear()
  failWrite = undefined
  failDelete = undefined
  failRead = undefined
  readHook = undefined
})

describe("Android session persistence", () => {
  test("concurrent save and clear operations leave no mixed authority", async () => {
    await Promise.all([
      saveSession({ token: "41:first", userId: 41, user: { id: 41 } }),
      saveSession({ token: "42:second", userId: 42, user: { id: 42 } }),
    ])
    expect(await loadSession()).toMatchObject({ token: "42:second", userId: 42, user: { id: 42 } })
    await Promise.all([saveSession({ token: "43:third", userId: 43 }), clearSession()])
    expect(await loadSession()).toBeNull()
  })

  test.each(["inline.auth.token", "inline.auth.userId", "inline.auth.user"])(
    "cleanup attempts every key when %s cannot be deleted and can recover", async (key) => {
      await saveSession({ token: "42:test", userId: 42, user: { id: 42 } })
      failDelete = key
      await expect(clearSession()).rejects.toThrow("fully cleared")
      expect([...values.keys()]).toEqual([key])
      expect(await loadSession()).toBeNull()
      failDelete = undefined
      await clearSession()
      await saveSession({ token: "43:retry", userId: 43 })
      expect((await loadSession())?.userId).toBe(43)
    },
  )

  test("unreadable optional metadata preserves authority while unreadable tokens fail visibly", async () => {
    await saveSession({ token: "42:test-token", userId: 42 })
    failRead = "inline.auth.user"
    expect(await loadSession()).toEqual({ token: "42:test-token", userId: 42, user: undefined })
    failRead = "inline.auth.token"
    await expect(loadSession()).rejects.toThrow("Secure storage unavailable")
  })

  test("a reader spanning account replacement cannot return mixed authority", async () => {
    await saveSession({ token: "41:old-token", userId: 41, user: { id: 41 } })
    let reached!: () => void
    let release!: () => void
    const started = new Promise<void>((resolve) => { reached = resolve })
    const paused = new Promise<void>((resolve) => { release = resolve })
    readHook = async (key) => {
      if (key !== "inline.auth.token") return
      readHook = undefined
      reached()
      await paused
    }
    const loading = loadSession()
    await started
    await saveSession({ token: "42:new-token", userId: 42, user: { id: 42 } })
    release()
    expect(await loading).toBeNull()
    expect((await loadSession())?.userId).toBe(42)
  })

  test("rejects mixed identity left by an older interrupted writer", async () => {
    values.set("inline.auth.token", "41:old-token")
    values.set("inline.auth.userId", "42")
    expect(await loadSession()).toBeNull()
  })

  test("corrupt optional profile metadata does not discard valid authority", async () => {
    await saveSession({ token: "42:test-token", userId: 42 })
    values.set("inline.auth.user", "{invalid")
    expect(await loadSession()).toEqual({ token: "42:test-token", userId: 42, user: undefined })
  })

  test("another account's profile is never displayed", async () => {
    await saveSession({ token: "42:test-token", userId: 42 })
    values.set("inline.auth.user", JSON.stringify({ id: 41, firstName: "Previous account" }))
    expect((await loadSession())?.user).toBeUndefined()
  })

  test("saving without a profile removes previous profile metadata", async () => {
    await saveSession({ token: "41:old-token", userId: 41, user: { id: 41, firstName: "Previous" } })
    await saveSession({ token: "42:new-token", userId: 42 })
    expect(values.has("inline.auth.user")).toBe(false)
    expect((await loadSession())?.user).toBeUndefined()
  })

  test.each(["0", "-1", "1.5", "9007199254740992", "invalid"])(
    "rejects invalid persisted account id %s",
    async (userId) => {
      values.set("inline.auth.token", "42:test-token")
      values.set("inline.auth.userId", userId)
      expect(await loadSession()).toBeNull()
    },
  )

  test.each(["inline.auth.userId", "inline.auth.user", "inline.auth.token"])(
    "interrupted replacement at %s never publishes mixed authority",
    async (key) => {
      await saveSession({ token: "41:old-token", userId: 41, user: { id: 41 } })
      failWrite = key
      await expect(saveSession({ token: "42:new-token", userId: 42, user: { id: 42 } })).rejects.toThrow()
      expect(await loadSession()).toBeNull()
    },
  )

  test("accepts matching string ids and ignores malformed display fields", async () => {
    await saveSession({ token: "42:test-token", userId: 42 })
    values.set("inline.auth.user", JSON.stringify({ id: "42", firstName: "Mo", username: {} }))
    expect((await loadSession())?.user).toEqual({
      id: 42, firstName: "Mo", lastName: undefined, username: undefined, email: undefined,
    })
  })
})
