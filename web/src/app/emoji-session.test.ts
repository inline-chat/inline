import type { Trigger } from "@inline/composer"
import type { UserID } from "@inline/ids"
import { describe, expect, it } from "vitest"
import * as emojiLight from "../features/emoji"
import type { EmojiChunk } from "../features/emoji"
import { accountEmojiStore, combinedSuggest, emojiStoragePrefix, eraseAccountEmoji, SessionEmoji, type EmojiModules } from "./emoji-session"
import { memoryStorage } from "./test-fixtures"

const ada = "7" as UserID
const alan = "8" as UserID

const emojiTrigger = (query: string): Trigger => ({ kind: "emoji", query, range: { from: 0, to: query.length + 1 } })

/** The real light half, with the table's import counted. The pickers' chunk is a stand-in (it is views). */
const modules = () => {
  const counts = { services: 0, pickers: 0, table: 0 }
  const pickers = { ReactionPickerController: class {} } as unknown as EmojiChunk
  const value: EmojiModules = {
    services: async () => {
      counts.services++
      return {
        createEmojiSuggest: emojiLight.createEmojiSuggest,
        createEmojiServices: (options) =>
          emojiLight.createEmojiServices({
            ...options,
            // A drawability check without a canvas: everything draws.
            support: emojiLight.createEmojiSupport({ probe: () => undefined, schedule: () => {} } as never),
            importEngine: () => {
              counts.table++
              return emojiLight.importEmojiEngine()
            },
          }),
      }
    },
    pickers: async () => {
      counts.pickers++
      return pickers
    },
  }
  return { value, counts, pickers }
}

const settle = async () => {
  for (let i = 0; i < 50; i++) await new Promise((resolve) => setTimeout(resolve, 0))
}

describe("emoji for an account", () => {
  it("loads nothing until warmed or used; the warm-up loads the code, never the table", async () => {
    const m = modules()
    const emoji = new SessionEmoji({ userId: ada, storage: memoryStorage(), modules: m.value })
    expect(m.counts).toEqual({ services: 0, pickers: 0, table: 0 })
    await emoji.warm()
    expect(m.counts).toEqual({ services: 1, pickers: 1, table: 0 })
    expect(emoji.services.peek()).toBeDefined()
    expect(emoji.pickers.peek()).toBe(m.pickers)
    // The first real use loads the table, once.
    await emoji.use()
    await emoji.use()
    await settle()
    expect(m.counts.table).toBe(1)
    emoji.dispose()
  })

  it("warms the table on its own (the idle lane's last task) without the pickers, so a picker opens with its data", async () => {
    const m = modules()
    const emoji = new SessionEmoji({ userId: ada, storage: memoryStorage(), modules: m.value })
    await emoji.warmData()
    expect(m.counts).toEqual({ services: 1, pickers: 0, table: 1 })
    expect(emoji.services.peek()?.loader.engine.peek()).toBeDefined()
    // The first use finds it there: the table is not loaded again.
    await emoji.use()
    await settle()
    expect(m.counts.table).toBe(1)
    emoji.dispose()
  })

  it("answers the composer's `:` with nothing at first, starts loading, and fills in when the table arrives", async () => {
    const m = modules()
    const emoji = new SessionEmoji({ userId: ada, storage: memoryStorage(), modules: m.value })
    expect(emoji.suggest(emojiTrigger("thumbsup"))).toEqual([])
    await settle()
    expect(m.counts.services).toBe(1)
    expect(m.counts.table).toBe(1)
    const rows = emoji.suggest(emojiTrigger("thumbsup"))
    expect(rows[0]).toMatchObject({ title: ":thumbsup:", item: { kind: "emoji", text: "👍" } })
    // Other triggers are not emoji's.
    expect(emoji.suggest({ kind: "mention", query: "a", range: { from: 0, to: 2 } })).toEqual([])
    emoji.dispose()
  })

  it("keeps recents and the skin tone per account under its own prefix, and sign-out erases only that account's", async () => {
    const storage = memoryStorage()
    const asStorage = {
      get length() {
        return storage.values.size
      },
      key: (index: number) => [...storage.values.keys()][index] ?? null,
      removeItem: (key: string) => storage.removeItem(key),
    }
    const m = modules()
    const emoji = new SessionEmoji({ userId: ada, storage, modules: m.value })
    await emoji.use()
    await settle()
    emoji.recordAccepted("🎉")
    emoji.services.peek()!.usage.setSkinTone("medium")
    accountEmojiStore(storage, alan).set(emojiLight.USAGE_KEYS.skinTone, "dark")
    storage.setItem("inline:workspace:7", "{}")
    const adaKeys = [...storage.values.keys()].filter((key) => key.startsWith(emojiStoragePrefix(ada)))
    expect(adaKeys).toEqual(
      expect.arrayContaining([`${emojiStoragePrefix(ada)}${emojiLight.USAGE_KEYS.frecency}`, `${emojiStoragePrefix(ada)}${emojiLight.USAGE_KEYS.skinTone}`]),
    )
    // Nothing under the Mac's bare keys: usage never leaks between accounts on this browser.
    expect(storage.getItem(emojiLight.USAGE_KEYS.frecency)).toBeNull()

    eraseAccountEmoji(asStorage, ada)
    expect([...storage.values.keys()].filter((key) => key.startsWith(emojiStoragePrefix(ada)))).toEqual([])
    expect(accountEmojiStore(storage, alan).get(emojiLight.USAGE_KEYS.skinTone)).toBe("dark")
    expect(storage.getItem("inline:workspace:7")).toBe("{}")
    emoji.dispose()
  })

  it("serves `@` and `:` through one suggest", () => {
    const asked: string[] = []
    const mentions = (trigger: Trigger) => {
      asked.push(trigger.kind)
      return []
    }
    const m = modules()
    const emoji = new SessionEmoji({ userId: ada, storage: memoryStorage(), modules: m.value, defer: () => {} })
    const suggest = combinedSuggest(mentions, emoji)
    suggest({ kind: "mention", query: "a", range: { from: 0, to: 2 } })
    suggest(emojiTrigger("smi"))
    expect(asked).toEqual(["mention"])
    // Without emoji wired, `:` lists nothing.
    expect(combinedSuggest(mentions, undefined)(emojiTrigger("smi"))).toEqual([])
  })
})
