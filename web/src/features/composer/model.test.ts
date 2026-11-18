import {
  createComposerController,
  type AutocompleteItem,
  type KeyInput,
  type SendKey,
  type SendOutcome,
  type SendRequest,
  type Trigger,
} from "@inline/composer"
import { messageId, userId } from "@inline/ids"
import { effect, manualTime, signal } from "@inline/reactive"
import { afterEach, describe, expect, it } from "vitest"
import { createComposerAutocomplete, type ComposerSuggestion } from "./autocomplete"
import { createAutocompleteCursor } from "./autocomplete-cursor"

/** The cursor without the popup view (the view needs the StyleX compiler). */
const cursorChunk = { createAutocompleteCursor }
import { createComposerModel, type ComposerModel, type ComposerModelOptions, type MessagePreview } from "./model"

/**
 * The view model without a DOM: the real composer controller on a virtual
 * clock, the real UI kit listbox, and the caller's functions recorded. The
 * DOM parts (`surface`, `popup`) are browser glue and are checked in the lab.
 */

const safeUrl = (url: string) => (/^https?:\/\//.test(url) ? url : null)

const people = [
  { id: "1", name: "Ada Lovelace", username: "ada" },
  { id: "2", name: "Alan Turing", username: "alan" },
  { id: "3", name: "Grace Hopper", username: "grace" },
]

const mentionRows = (query: string): ComposerSuggestion[] =>
  people
    .filter((p) => p.name.toLowerCase().includes(query.toLowerCase()) || p.username.startsWith(query.toLowerCase()))
    .map((p) => ({
      id: p.id,
      title: p.name,
      subtitle: `@${p.username}`,
      item: { kind: "mention", atom: { type: "mention", userId: userId(p.id) }, label: `@${p.name}` },
    }))

const plain = (k: string, mods: Partial<KeyInput> = {}): KeyInput => ({
  key: k,
  shiftKey: false,
  altKey: false,
  ctrlKey: false,
  metaKey: false,
  ...mods,
})

let model: ComposerModel | undefined
afterEach(() => {
  model?.dispose()
  model = undefined
})

const setup = (overrides: Partial<ComposerModelOptions> = {}) => {
  const time = manualTime()
  const sent: SendRequest[] = []
  const settle: ((outcome: SendOutcome) => void)[] = []
  model = createComposerModel({
    autocompleteChunk: cursorChunk,
    clock: time,
    safeUrl,
    platform: "mac",
    send: (request) => {
      sent.push(request)
      return new Promise<SendOutcome>((resolve) => settle.push(resolve))
    },
    suggest: (trigger) => (trigger.kind === "mention" ? mentionRows(trigger.query) : []),
    ...overrides,
  })
  return { model, time, sent, settle }
}

const flush = async () => {
  await Promise.resolve()
  await Promise.resolve()
}

describe("autocomplete list", () => {
  const make = () => {
    const trigger = signal<Trigger | null>(null)
    const focused = signal(true)
    const accepted: AutocompleteItem[] = []
    let calls = 0
    const ac = createComposerAutocomplete({
      chunk: cursorChunk,
      trigger,
      focused,
      suggest: (t) => {
        calls += 1
        return t.kind === "mention" ? mentionRows(t.query) : []
      },
      accept: (item) => {
        accepted.push(item)
        return true
      },
    })
    const stop = effect(() => {
      // Observe like the view does.
      ac.suggestions.get()
      ac.isOpen.get()
      ac.activeDescendant.get()
    })
    const at = (query: string, from = 0): Trigger => ({ kind: "mention", query, range: { from, to: from + 1 + query.length } })
    return { trigger, focused, accepted, ac, at, calls: () => calls, dispose: () => (stop(), ac.dispose()) }
  }

  it("opens with rows for the trigger, cursor on the first row", () => {
    const t = make()
    expect(t.ac.isOpen.peek()).toBe(false)
    t.trigger.set(t.at("a"))
    expect(t.ac.suggestions.peek().map((s) => s.id)).toEqual(["1", "2", "3"])
    expect(t.ac.isOpen.peek()).toBe(true)
    expect(t.ac.cursor.peek()!.listbox.activeId.peek()).toBe("1")
    expect(t.ac.activeDescendant.peek()).toBe(t.ac.cursor.peek()!.listbox.optionDomId("1"))
    t.dispose()
  })

  it("moves with next and previous without wrapping, and accepts the active row", () => {
    const t = make()
    t.trigger.set(t.at("a"))
    expect(t.ac.handleKey("previous")).toBe(true)
    expect(t.ac.cursor.peek()!.listbox.activeId.peek()).toBe("1")
    t.ac.handleKey("next")
    t.ac.handleKey("next")
    t.ac.handleKey("next")
    expect(t.ac.cursor.peek()!.listbox.activeId.peek()).toBe("3")
    expect(t.ac.handleKey("accept")).toBe(true)
    expect(t.accepted).toHaveLength(1)
    expect(t.accepted[0]).toMatchObject({ kind: "mention", label: "@Grace Hopper" })
    t.dispose()
  })

  it("puts the cursor back on the first row when the query changes", () => {
    const t = make()
    t.trigger.set(t.at("a"))
    t.ac.handleKey("next")
    expect(t.ac.cursor.peek()!.listbox.activeId.peek()).toBe("2")
    t.trigger.set(t.at("l"))
    expect(t.ac.suggestions.peek().map((s) => s.id)).toEqual(["1", "2"])
    expect(t.ac.cursor.peek()!.listbox.activeId.peek()).toBe("1")
    t.dispose()
  })

  it("keeps the cursor when the same query gets new rows", () => {
    const rows = signal<ComposerSuggestion[]>(mentionRows("a"))
    const trigger = signal<Trigger | null>({ kind: "mention", query: "a", range: { from: 0, to: 2 } })
    const ac = createComposerAutocomplete({
      chunk: cursorChunk, trigger, focused: signal(true), suggest: () => rows.get(), accept: () => true })
    const stop = effect(() => void ac.suggestions.get())
    ac.handleKey("next")
    expect(ac.cursor.peek()!.listbox.activeId.peek()).toBe("2")
    rows.set([...mentionRows("a"), { id: "4", title: "Alan Kay", item: { kind: "emoji", text: "x" } }])
    expect(ac.cursor.peek()!.listbox.activeId.peek()).toBe("2")
    rows.set(mentionRows("grace"))
    expect(ac.cursor.peek()!.listbox.activeId.peek()).toBe("3")
    stop()
    ac.dispose()
  })

  it("leaves every key to the composer when no rows are shown", () => {
    const t = make()
    t.trigger.set(t.at("zzz"))
    expect(t.ac.isOpen.peek()).toBe(false)
    for (const k of ["next", "previous", "accept", "dismiss"] as const) expect(t.ac.handleKey(k)).toBe(false)
    expect(t.accepted).toHaveLength(0)
    t.dispose()
  })

  it("hides while the editor is not focused, and leaves Escape to the controller", () => {
    const t = make()
    t.trigger.set(t.at("a"))
    t.focused.set(false)
    expect(t.ac.isOpen.peek()).toBe(false)
    expect(t.ac.activeDescendant.peek()).toBeNull()
    expect(t.ac.handleKey("accept")).toBe(false)
    t.focused.set(true)
    expect(t.ac.isOpen.peek()).toBe(true)
    expect(t.ac.handleKey("dismiss")).toBe(false)
    t.dispose()
  })

  it("accepts a row by id (pointer) and survives a failing source", () => {
    const t = make()
    t.trigger.set(t.at("gr"))
    expect(t.ac.accept("3")).toBe(true)
    expect(t.ac.accept("nope")).toBe(false)
    const broken = createComposerAutocomplete({
      chunk: cursorChunk,
      trigger: signal<Trigger | null>(t.at("a")),
      focused: signal(true),
      suggest: () => {
        throw new Error("source down")
      },
      accept: () => true,
    })
    expect(broken.suggestions.peek()).toEqual([])
    expect(broken.isOpen.peek()).toBe(false)
    broken.dispose()
    t.dispose()
  })

  it("takes arrows, Enter and Tab from the composer's key routing, and Escape dismisses", () => {
    const focused = signal(true)
    let ac: ReturnType<typeof createComposerAutocomplete> | null = null
    const sent: SendRequest[] = []
    const composer = createComposerController({
      clock: manualTime(),
      safeUrl,
      platform: "mac",
      send: (request) => {
        sent.push(request)
        return { status: "accepted" }
      },
      onAutocompleteKey: (k) => ac?.handleKey(k) ?? false,
    })
    ac = createComposerAutocomplete({
      chunk: cursorChunk,
      trigger: composer.autocomplete,
      focused,
      suggest: (t) => mentionRows(t.query),
      accept: (item) => composer.acceptAutocomplete(item),
    })
    const stop = effect(() => void ac!.isOpen.get())
    composer.insertText("@a")
    expect(ac.isOpen.peek()).toBe(true)
    expect(composer.handleKeyDown(plain("ArrowDown"))).toBe(true)
    expect(ac.cursor.peek()!.listbox.activeId.peek()).toBe("2")
    expect(composer.handleKeyDown(plain("Enter"))).toBe(true)
    expect(sent).toHaveLength(0)
    expect(composer.doc.peek().text).toBe("@Alan Turing ")
    expect(ac.isOpen.peek()).toBe(false)

    composer.insertText("@gr")
    expect(composer.handleKeyDown(plain("Tab"))).toBe(true)
    expect(composer.doc.peek().text).toBe("@Alan Turing @Grace Hopper ")

    composer.insertText("@a")
    expect(composer.handleKeyDown(plain("Escape"))).toBe(true)
    expect(ac.isOpen.peek()).toBe(false)
    expect(composer.handleKeyDown(plain("Enter"))).toBe(true)
    expect(sent).toHaveLength(1)

    composer.insertText("@zz")
    expect(ac.isOpen.peek()).toBe(false)
    expect(composer.handleKeyDown(plain("ArrowDown"))).toBe(false)
    expect(composer.handleKeyDown(plain("a", { isComposing: true }))).toBe(false)
    stop()
    ac.dispose()
    composer.dispose()
  })

  it("calls the source once per query, not per read", () => {
    const t = make()
    t.trigger.set(t.at("a"))
    const before = t.calls()
    t.ac.suggestions.peek()
    t.ac.isOpen.peek()
    t.ac.handleKey("next")
    expect(t.calls()).toBe(before)
    t.dispose()
  })
})

describe("composer model", () => {
  it("routes autocomplete keys from the composer and inserts the mention as an atom", () => {
    const { model: m } = setup()
    // Without a surface the editor is not focused, so the list stays closed and Enter keeps its meaning.
    m.composer.insertText("hi @al")
    expect(m.composer.autocomplete.peek()?.query).toBe("al")
    expect(m.autocomplete.isOpen.peek()).toBe(false)
    // Accept through the list as a pointer click would.
    expect(m.autocomplete.accept("2")).toBe(true)
    const doc = m.composer.doc.peek()
    expect(doc.text).toBe("hi @Alan Turing ")
    expect(doc.entities).toEqual([{ type: "mention", offset: 3, length: 12, userId: userId("2") }])
  })

  it("sends with the controller's key rule and keeps text after a rejection, in words", async () => {
    const { model, sent, settle } = setup()
    model.composer.insertText("hello")
    expect(model.composer.handleKeyDown(plain("Enter"))).toBe(true)
    expect(sent).toHaveLength(1)
    expect(model.composer.sending.peek()).toBe(true)
    settle.shift()!({ status: "rejected", reason: "storageFull" })
    await flush()
    expect(model.composer.doc.peek().text).toBe("hello")
    expect(model.errorText.peek()).toMatch(/storage/)
    model.composer.insertText("!")
    expect(model.errorText.peek()).toBeNull()
    model.send()
    settle.shift()!({ status: "accepted" })
    await flush()
    expect(model.composer.doc.peek().text).toBe("")
  })

  it("follows a send key signal for the controller and the hint", () => {
    const sendKey = signal<SendKey>("enter")
    const { model, sent } = setup({ sendKey })
    expect(model.sendHint.peek()).toBe("↩ to send, ⇧↩ for a new line")
    sendKey.set("modEnter")
    expect(model.sendHint.peek()).toBe("⌘↩ to send")
    model.composer.insertText("x")
    model.composer.handleKeyDown(plain("Enter"))
    expect(sent).toHaveLength(0)
    expect(model.composer.doc.peek().text).toBe("x\n")
    model.composer.handleKeyDown(plain("Enter", { metaKey: true }))
    expect(sent).toHaveLength(1)
  })

  it("describes the reply and edit banners, preferring the edit, and dismisses each", () => {
    const previews = signal<Record<string, MessagePreview>>({ "10": { senderName: "Ada", text: "First" } })
    const { model } = setup({ describeMessage: (id) => previews.get()[id] ?? null })
    expect(model.banner.peek()).toBeNull()
    model.composer.setReply({ messageId: messageId("10") })
    expect(model.banner.peek()).toEqual({ kind: "reply", messageId: "10", preview: { senderName: "Ada", text: "First" } })
    const before = model.banner.peek()
    previews.set({ ...previews.peek() })
    expect(model.banner.peek()).toBe(before)
    previews.set({ "10": { senderName: "Ada", text: "First, edited" } })
    expect(model.banner.peek()?.preview?.text).toBe("First, edited")
    model.dismissBanner()
    expect(model.composer.reply.peek()).toBeNull()

    model.composer.insertText("draft")
    model.composer.startEdit({ messageId: messageId("11") }, { text: "old" })
    expect(model.banner.peek()).toEqual({ kind: "edit", messageId: "11", preview: null })
    model.dismissBanner()
    expect(model.composer.editing.peek()).toBeNull()
    expect(model.composer.doc.peek().text).toBe("draft")
  })

  it("is empty only with no text", () => {
    const { model } = setup({ initial: { text: "kept", revision: 4 } })
    expect(model.empty.peek()).toBe(false)
    model.composer.setDraft({ text: "", revision: 5 })
    expect(model.empty.peek()).toBe(true)
  })

  it("cannot focus before the surface is attached", () => {
    const { model } = setup()
    expect(model.focus()).toBe(false)
    expect(model.focused.peek()).toBe(false)
  })

  it("flushes the pending draft when disposed", () => {
    const saved: string[] = []
    const { model: m } = setup({ saveDraft: (text) => saved.push(text) })
    m.composer.insertText("unsaved")
    m.dispose()
    model = undefined
    expect(saved).toEqual(["unsaved"])
  })
})

describe("suggestion accept hook", () => {
  it("calls a row's onAccept once per accepted row, after it is inserted, never for a dismissed list", () => {
    const calls: string[] = []
    const rows = (query: string) =>
      mentionRows(query).map((row) => ({ ...row, onAccept: () => calls.push(`${row.id}:${model?.composer.doc.peek().text}`) }))
    const { model: m } = setup({ suggest: (trigger) => (trigger.kind === "mention" ? rows(trigger.query) : []) })
    m.composer.insertText("@al")
    // Escape dismisses the list: nothing accepted.
    m.composer.handleKeyDown(plain("Escape"))
    expect(m.composer.autocomplete.peek()).toBeNull()
    expect(calls).toEqual([])
    m.composer.insertText(" @gr")
    expect(m.autocomplete.accept("3")).toBe(true)
    expect(calls).toEqual(["3:@al @Grace Hopper "])
    // A row that is not in the list (stale click) accepts nothing.
    expect(m.autocomplete.accept("3")).toBe(false)
    expect(calls).toHaveLength(1)
  })

  it("keeps mentions working without a hook, and a throwing hook never undoes the insertion", () => {
    const { model: m } = setup({
      suggest: (trigger) =>
        mentionRows(trigger.query).map((row) => ({
          ...row,
          onAccept: () => {
            throw new Error("recents store down")
          },
        })),
    })
    m.composer.insertText("@ad")
    expect(m.autocomplete.accept("1")).toBe(true)
    expect(m.composer.doc.peek().entities).toEqual([{ type: "mention", offset: 0, length: 13, userId: userId("1") }])
  })
})

describe("the autocomplete chunk loads on the first trigger", () => {
  const lazySetup = () => {
    let arrive!: (chunk: { createAutocompleteCursor: typeof createAutocompleteCursor }) => void
    let loads = 0
    const focused = signal(true)
    const ctx = setup({
      autocompleteChunk: () => {
        loads += 1
        return new Promise((resolve) => (arrive = resolve))
      },
    })
    // The editor is focused (the surface part would say so).
    return { ...ctx, focused, loads: () => loads, arrive: (c = cursorChunk) => arrive(c) }
  }

  it("does not load it for plain typing; loads once on the first @, with the list closed and keys plain until it arrives", async () => {
    const t = lazySetup()
    t.model.composer.insertText("hello")
    expect(t.loads()).toBe(0)
    expect(t.model.autocomplete.cursor.peek()).toBeNull()
    t.model.composer.insertText(" @al")
    expect(t.loads()).toBe(1)
    expect(t.model.autocomplete.suggestions.peek().map((r) => r.id)).toEqual(["2"])
    expect(t.model.autocomplete.isOpen.peek()).toBe(false)
    // A key typed before the chunk arrives keeps its plain meaning and its order.
    expect(t.model.composer.handleKeyDown(plain("ArrowDown"))).toBe(false)
    t.model.composer.insertText("a")
    t.model.composer.insertText("n")
    expect(t.model.composer.doc.peek().text).toBe("hello @alan")
    t.model.composer.insertText(" ")
    t.model.composer.insertText("@")
    expect(t.loads()).toBe(1)
    t.arrive()
    await flush()
    expect(t.model.autocomplete.cursor.peek()).not.toBeNull()
    expect(t.model.composer.doc.peek().text).toBe("hello @alan @")
  })

  it("makes the cursor in the same task as the trigger when the chunk is already here", () => {
    const { model: m } = setup({ autocompleteChunk: cursorChunk })
    m.composer.insertText("@a")
    expect(m.autocomplete.cursor.peek()).not.toBeNull()
  })
})
