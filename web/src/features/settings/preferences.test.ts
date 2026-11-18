import { effect, signal } from "@inline/reactive"
import { describe, expect, it } from "vitest"
import {
  DEFAULT_PREFERENCES,
  memoryPreferencesHub,
  memoryPreferencesStorage,
  parsePreferences,
  PREFERENCES_STORAGE_KEY,
  PreferencesStore,
  webPreferencesStorage,
  type PreferenceValues,
} from "./preferences"

describe("parsePreferences", () => {
  it("returns the Mac defaults for nothing, garbage and wrong shapes", () => {
    for (const input of [undefined, null, "", "not json", "[]", 42, [], "null", '"text"']) {
      expect(parsePreferences(input)).toEqual(DEFAULT_PREFERENCES)
    }
    expect(DEFAULT_PREFERENCES).toMatchObject({
      sendKey: "enter",
      spellCheck: true,
      replyThreadsInSidePane: false,
      notificationSounds: true,
      appBadge: true,
    })
  })

  it("keeps valid fields and defaults invalid ones", () => {
    const parsed = parsePreferences(
      JSON.stringify({ version: 1, sendKey: "modEnter", spellCheck: "yes", appBadge: false, notificationSounds: 0 }),
    )
    expect(parsed).toEqual({ ...DEFAULT_PREFERENCES, sendKey: "modEnter", appBadge: false })
  })

  it("migrates an unversioned object with the Mac app's names", () => {
    const parsed = parsePreferences({
      sendsWithCmdEnter: true,
      checkSpellingWhileTyping: false,
      openReplyThreadsInSidePane: true,
      disableNotificationSound: true,
      showDockBadgeUnreadDMs: false,
    })
    expect(parsed).toEqual({
      version: 1,
      sendKey: "modEnter",
      spellCheck: false,
      replyThreadsInSidePane: true,
      notificationSounds: false,
      appBadge: false,
    })
  })

  it("prefers current names over legacy ones in an unversioned object", () => {
    expect(parsePreferences({ sendsWithCmdEnter: true, sendKey: "enter" }).sendKey).toBe("enter")
    expect(parsePreferences({ sendKey: "return" }).sendKey).toBe("enter")
    expect(parsePreferences({ sendKey: "cmdEnter" }).sendKey).toBe("modEnter")
  })

  it("does not read legacy names in a versioned object", () => {
    expect(parsePreferences({ version: 1, sendsWithCmdEnter: true }).sendKey).toBe("enter")
  })

  it("reads a newer version field by field", () => {
    expect(parsePreferences({ version: 7, sendKey: "modEnter", spellCheck: false, somethingNew: { a: 1 } })).toEqual({
      ...DEFAULT_PREFERENCES,
      sendKey: "modEnter",
      spellCheck: false,
    })
  })
})

const setup = (initial?: Record<string, string>) => {
  const storage = memoryPreferencesStorage(initial)
  const store = new PreferencesStore({ storage })
  return { storage, store }
}

describe("PreferencesStore", () => {
  it("reads storage before the first frame", () => {
    const { store } = setup({ [PREFERENCES_STORAGE_KEY]: JSON.stringify({ version: 1, sendKey: "modEnter" }) })
    expect(store.sendKey.peek()).toBe("modEnter")
    expect(store.spellCheck.peek()).toBe(true)
  })

  it("applies a setter to the signal and storage in the same task", () => {
    const { store, storage } = setup()
    const seen: boolean[] = []
    const stop = effect(() => {
      seen.push(store.spellCheck.get())
    })
    store.setSpellCheck(false)
    expect(seen).toEqual([true, false])
    expect(JSON.parse(storage.entries.get(PREFERENCES_STORAGE_KEY) ?? "{}")).toEqual({
      ...DEFAULT_PREFERENCES,
      spellCheck: false,
    })
    stop()
  })

  it("ignores invalid patches and does not write unchanged values", () => {
    const { store, storage } = setup()
    store.update({ sendKey: "space", appBadge: "no" })
    store.setAppBadge(true)
    expect(storage.entries.size).toBe(0)
    expect(store.value.peek()).toEqual(DEFAULT_PREFERENCES)
  })

  it("only notifies the field that changed", () => {
    const { store } = setup()
    let sendKeyRuns = 0
    const stop = effect(() => {
      store.sendKey.get()
      sendKeyRuns++
    })
    store.setAppBadge(false)
    store.setNotificationSounds(false)
    expect(sendKeyRuns).toBe(1)
    store.setSendKey("modEnter")
    expect(sendKeyRuns).toBe(2)
    stop()
  })

  it("migrates a stored legacy object and writes the current version back on the next change", () => {
    const { store, storage } = setup({ [PREFERENCES_STORAGE_KEY]: JSON.stringify({ sendsWithCmdEnter: true }) })
    expect(store.sendKey.peek()).toBe("modEnter")
    store.setAppBadge(false)
    expect(JSON.parse(storage.entries.get(PREFERENCES_STORAGE_KEY) ?? "{}")).toEqual({
      version: 1,
      sendKey: "modEnter",
      spellCheck: true,
      replyThreadsInSidePane: false,
      notificationSounds: true,
      appBadge: false,
    })
  })

  it("keeps a newer build's unknown fields when it writes", () => {
    const stored = { version: 2, sendKey: "enter", spellCheck: true, futureField: [1, 2] }
    const { store, storage } = setup({ [PREFERENCES_STORAGE_KEY]: JSON.stringify(stored) })
    store.setSpellCheck(false)
    const written = JSON.parse(storage.entries.get(PREFERENCES_STORAGE_KEY) ?? "{}")
    expect(written.futureField).toEqual([1, 2])
    expect(written.spellCheck).toBe(false)
    expect(written.version).toBe(1)
  })

  it("survives storage that throws", () => {
    const broken = webPreferencesStorage({
      getItem: () => {
        throw new Error("blocked")
      },
      setItem: () => {
        throw new Error("quota")
      },
    })
    const store = new PreferencesStore({ storage: broken })
    expect(store.value.peek()).toEqual(DEFAULT_PREFERENCES)
    store.setSendKey("modEnter")
    expect(store.sendKey.peek()).toBe("modEnter")
  })

  it("reset returns to the defaults", () => {
    const { store } = setup()
    store.update({ sendKey: "modEnter", spellCheck: false, appBadge: false })
    store.reset()
    expect(store.value.peek()).toEqual(DEFAULT_PREFERENCES)
  })

  it("reload re-reads storage", () => {
    const { store, storage } = setup()
    storage.write(PREFERENCES_STORAGE_KEY, JSON.stringify({ version: 1, replyThreadsInSidePane: true }))
    store.reload()
    expect(store.replyThreadsInSidePane.peek()).toBe(true)
  })
})

describe("cross-tab", () => {
  const twoTabs = () => {
    const hub = memoryPreferencesHub()
    const storage = memoryPreferencesStorage()
    const a = new PreferencesStore({ storage, channel: hub.channel() })
    const b = new PreferencesStore({ storage, channel: hub.channel() })
    return { a, b, storage }
  }

  it("a change in one tab applies in the other in the same task", () => {
    const { a, b } = twoTabs()
    const seen: string[] = []
    const stop = effect(() => {
      seen.push(b.sendKey.get())
    })
    a.setSendKey("modEnter")
    expect(seen).toEqual(["enter", "modEnter"])
    expect(b.value.peek()).toEqual(a.value.peek())
    stop()
  })

  it("does not echo: the receiver neither writes storage nor posts back", () => {
    const hub = memoryPreferencesHub()
    const storageA = memoryPreferencesStorage()
    const storageB = memoryPreferencesStorage()
    const a = new PreferencesStore({ storage: storageA, channel: hub.channel() })
    const b = new PreferencesStore({ storage: storageB, channel: hub.channel() })
    let aChanges = 0
    const stop = effect(() => {
      a.value.get()
      aChanges++
    })
    a.setAppBadge(false)
    expect(b.appBadge.peek()).toBe(false)
    expect(storageB.entries.size).toBe(0)
    expect(aChanges).toBe(2)
    stop()
  })

  it("ignores foreign and malformed messages and its own echo", () => {
    const listeners: ((message: unknown) => void)[] = []
    const store = new PreferencesStore({
      storage: memoryPreferencesStorage(),
      instanceId: "me",
      channel: {
        post: (message) => listeners.forEach((listener) => listener(message)),
        subscribe: (listener) => {
          listeners.push(listener)
          return () => undefined
        },
      },
    })
    const deliver = (message: unknown) => listeners.forEach((listener) => listener(message))
    deliver("hello")
    deliver({ type: "other", from: "x", value: { version: 1, sendKey: "modEnter" } })
    deliver(null)
    expect(store.sendKey.peek()).toBe("enter")
    // Its own message coming back must not undo a newer local change.
    store.setSendKey("modEnter")
    deliver({ type: "inline.preferences", from: "me", value: { version: 1, sendKey: "enter" } })
    expect(store.sendKey.peek()).toBe("modEnter")
    deliver({ type: "inline.preferences", from: "other", value: { version: 1, sendKey: "enter" } })
    expect(store.sendKey.peek()).toBe("enter")
  })

  it("stops listening after dispose", () => {
    const { a, b } = twoTabs()
    b.dispose()
    a.setSpellCheck(false)
    expect(b.spellCheck.peek()).toBe(true)
    b.setSpellCheck(false)
    expect(b.spellCheck.peek()).toBe(true)
  })
})

describe("sync source", () => {
  const syncSource = (fields: (keyof PreferenceValues)[]) => {
    const values = signal<Partial<PreferenceValues> | undefined>(undefined)
    const writes: Partial<PreferenceValues>[] = []
    return {
      values,
      writes,
      source: {
        fields,
        values,
        write: (patch: Partial<PreferenceValues>) => {
          writes.push(patch)
          values.set({ ...values.peek(), ...patch })
        },
      },
    }
  }

  it("shows the local value until the core knows, then the core's", () => {
    const { store } = setup()
    store.setNotificationSounds(false)
    const sync = syncSource(["notificationSounds"])
    store.attachSync(sync.source)
    expect(store.notificationSounds.peek()).toBe(false)
    sync.values.set({ notificationSounds: true })
    expect(store.notificationSounds.peek()).toBe(true)
  })

  it("writes owned fields to the core and keeps the local cache current", () => {
    const { store, storage } = setup()
    const sync = syncSource(["notificationSounds"])
    store.attachSync(sync.source)
    store.update({ notificationSounds: false, appBadge: false })
    expect(sync.writes).toEqual([{ notificationSounds: false }])
    expect(store.notificationSounds.peek()).toBe(false)
    expect(JSON.parse(storage.entries.get(PREFERENCES_STORAGE_KEY) ?? "{}").notificationSounds).toBe(false)
  })

  it("ignores the core's values for fields it does not own, and invalid ones", () => {
    const { store } = setup()
    const sync = syncSource(["notificationSounds"])
    store.attachSync(sync.source)
    sync.values.set({ appBadge: false, notificationSounds: "loud" as unknown as boolean })
    expect(store.appBadge.peek()).toBe(true)
    expect(store.notificationSounds.peek()).toBe(true)
  })

  it("falls back to local values after detaching", () => {
    const { store } = setup()
    const sync = syncSource(["spellCheck"])
    const detach = store.attachSync(sync.source)
    sync.values.set({ spellCheck: false })
    expect(store.spellCheck.peek()).toBe(false)
    detach()
    expect(store.spellCheck.peek()).toBe(true)
  })
})
