import type { MessageID, UserID } from "@inline/ids"
import { manualTime, signal, type ManualTime } from "@inline/reactive"
import { describe, expect, it } from "vitest"
import {
  collapsed,
  createComposerController,
  type ComposerOptions,
  type KeyInput,
  type SendOutcome,
  type SendRequest,
} from "./index"
import type { PasteModule } from "./clipboard"

const safeUrl = (url: string) => (/^https?:\/\//.test(url) ? url : null)
const msg = (id: string) => id as MessageID

type Deferred = { resolve: (outcome: SendOutcome) => void; reject: (error: unknown) => void }

/** A controller with a virtual clock, a recording draft store and a send the test settles by hand. */
const setup = (overrides: Partial<ComposerOptions> = {}) => {
  const time: ManualTime = manualTime()
  const saves: { text: string; revision: number; entities: unknown[] }[] = []
  const sent: SendRequest[] = []
  const pending: Deferred[] = []
  const controller = createComposerController({
    clock: time,
    safeUrl,
    saveDraft: (text, entities, revision) => saves.push({ text, entities, revision }),
    send: (request) => {
      sent.push(request)
      return new Promise<SendOutcome>((resolve, reject) => pending.push({ resolve, reject }))
    },
    ...overrides,
  })
  const settle = async (outcome: SendOutcome) => {
    pending.shift()!.resolve(outcome)
    await Promise.resolve()
    await Promise.resolve()
  }
  return { time, saves, sent, pending, controller, settle }
}

const key = (k: string, mods: Partial<KeyInput> = {}): KeyInput => ({
  key: k,
  shiftKey: false,
  altKey: false,
  ctrlKey: false,
  metaKey: false,
  ...mods,
})

describe("draft persistence", () => {
  it("saves once after the debounce, with the latest revision", () => {
    const { time, saves, controller } = setup()
    controller.insertText("h")
    time.advance(200)
    controller.insertText("i")
    time.advance(299)
    expect(saves).toEqual([])
    time.advance(1)
    expect(saves).toEqual([{ text: "hi", entities: [], revision: controller.doc.peek().revision }])
    time.advance(1000)
    expect(saves).toHaveLength(1)
  })

  it("flushes a pending draft immediately and only once", () => {
    const { time, saves, controller } = setup()
    controller.insertText("x")
    expect(controller.hasPendingDraft()).toBe(true)
    controller.flushDraft()
    expect(saves.map((s) => s.text)).toEqual(["x"])
    expect(controller.hasPendingDraft()).toBe(false)
    time.advance(1000)
    controller.flushDraft()
    expect(saves).toHaveLength(1)
  })

  it("does not save a selection change, the initial draft or a restored draft", () => {
    const { time, saves, controller } = setup({ initial: { text: "draft", revision: 7 } })
    expect(controller.doc.peek().revision).toBe(7)
    controller.setSelection(collapsed(0))
    controller.setDraft({ text: "other chat", revision: 3 })
    time.advance(1000)
    controller.flushDraft()
    expect(saves).toEqual([])
  })

  it("saves formatting changes with their entities", () => {
    const { time, saves, controller } = setup({ initial: { text: "word", revision: 1 } })
    controller.setSelection({ anchor: 0, focus: 4 })
    controller.toggleMark("bold")
    time.advance(300)
    expect(saves[0]?.entities).toEqual([{ type: "bold", offset: 0, length: 4 }])
  })

  it("saves the pending draft on dispose", () => {
    const { saves, controller } = setup()
    controller.insertText("bye")
    controller.dispose()
    expect(saves.map((s) => s.text)).toEqual(["bye"])
  })
})

describe("send", () => {
  it("sends trimmed text with entities and the reply, and clears after acceptance", async () => {
    const { time, saves, sent, controller, settle } = setup()
    controller.setReply({ messageId: msg("5") })
    controller.insertText("  hello  ")
    const revision = controller.doc.peek().revision
    void controller.send()
    expect(sent).toEqual([{ kind: "send", text: "hello", entities: [], revision, replyTo: { messageId: msg("5") } }])
    expect(controller.doc.peek().text).toBe("  hello  ")
    expect(controller.canSend.peek()).toBe(false)
    await settle({ status: "accepted" })
    expect(controller.doc.peek().text).toBe("")
    expect(controller.doc.peek().revision).toBeGreaterThan(revision)
    expect(controller.reply.peek()).toBeNull()
    expect(controller.canUndo.peek()).toBe(false)
    // The pending save of the sent text was cancelled, and clearing saves nothing.
    time.advance(1000)
    controller.flushDraft()
    expect(saves).toEqual([])
  })

  it("keeps the text when the intent is rejected, says why, and saves the draft", async () => {
    const { time, saves, controller, settle } = setup()
    controller.insertText("keep me")
    void controller.send()
    await settle({ status: "rejected", reason: "storageFull" })
    expect(controller.doc.peek().text).toBe("keep me")
    expect(controller.error.peek()).toBe("storageFull")
    expect(controller.canSend.peek()).toBe(true)
    time.advance(300)
    expect(saves.map((s) => s.text)).toEqual(["keep me"])
    controller.insertText("!")
    expect(controller.error.peek()).toBeNull()
  })

  it("treats a send that throws as rejected", async () => {
    const { controller, pending } = setup()
    controller.insertText("x")
    void controller.send()
    pending.shift()!.reject(new Error("boom"))
    await Promise.resolve()
    await Promise.resolve()
    expect(controller.doc.peek().text).toBe("x")
    expect(controller.error.peek()).toBe("failed")
  })

  it("does not clear when the draft changed while the intent was committed", async () => {
    const { time, saves, controller, settle } = setup()
    controller.insertText("first")
    void controller.send()
    controller.insertText(" more")
    await settle({ status: "accepted" })
    expect(controller.doc.peek().text).toBe("first more")
    time.advance(300)
    expect(saves.map((s) => s.text)).toEqual(["first more"])
  })

  it("does not send twice while a send is pending, or send whitespace", async () => {
    const { sent, controller, settle } = setup()
    controller.insertText(" \n ")
    expect(controller.canSend.peek()).toBe(false)
    expect(await controller.send()).toBe(false)
    controller.insertText("a")
    void controller.send()
    void controller.send()
    expect(sent).toHaveLength(1)
    await settle({ status: "accepted" })
  })

  it("lets attachments make a message sendable", () => {
    const hasAttachments = signal(false)
    const { controller } = setup({ hasAttachments })
    expect(controller.canSend.peek()).toBe(false)
    hasAttachments.set(true)
    expect(controller.canSend.peek()).toBe(true)
  })
})

describe("edit", () => {
  it("edits a message, skips draft saves meanwhile, then restores the draft", async () => {
    const { time, saves, sent, controller, settle } = setup()
    controller.insertText("my draft")
    controller.startEdit({ messageId: msg("9") }, { text: "old text", entities: [{ type: "bold", offset: 0, length: 3 }] })
    expect(saves.map((s) => s.text)).toEqual(["my draft"])
    expect(controller.editing.peek()).toEqual({ messageId: msg("9") })
    controller.insertText(" edited")
    time.advance(1000)
    expect(saves).toHaveLength(1)
    void controller.send()
    expect(sent[0]).toMatchObject({ kind: "edit", text: "old text edited", edit: { messageId: msg("9") } })
    expect(sent[0]?.entities).toEqual([{ type: "bold", offset: 0, length: 3 }])
    await settle({ status: "accepted" })
    expect(controller.editing.peek()).toBeNull()
    expect(controller.doc.peek().text).toBe("my draft")
    time.advance(1000)
    expect(saves).toHaveLength(1)
  })

  it("cancels an edit with Escape and keeps the text of a rejected edit", async () => {
    const { controller, settle } = setup()
    controller.insertText("draft")
    controller.startEdit({ messageId: msg("1") }, { text: "message" })
    expect(controller.handleKeyDown(key("Escape"))).toBe(true)
    expect(controller.doc.peek().text).toBe("draft")
    controller.startEdit({ messageId: msg("1") }, { text: "message" })
    void controller.send()
    await settle({ status: "rejected" })
    expect(controller.doc.peek().text).toBe("message")
    expect(controller.editing.peek()).not.toBeNull()
  })
})

describe("keys", () => {
  it("sends with Enter, or with Mod+Enter when that is the preference", () => {
    const sendKey = signal<"enter" | "modEnter">("enter")
    const { sent, controller } = setup({ sendKey, platform: "mac" })
    controller.insertText("a")
    expect(controller.handleKeyDown(key("Enter", { shiftKey: true }))).toBe(true)
    expect(controller.doc.peek().text).toBe("a\n")
    sendKey.set("modEnter")
    controller.handleKeyDown(key("Enter"))
    expect(controller.doc.peek().text).toBe("a\n\n")
    expect(sent).toHaveLength(0)
    controller.handleKeyDown(key("Enter", { metaKey: true }))
    expect(sent).toHaveLength(1)
  })

  it("leaves keys alone during composition", () => {
    const { sent, controller } = setup()
    controller.insertText("a")
    expect(controller.handleKeyDown(key("Enter", { isComposing: true }))).toBe(false)
    expect(sent).toHaveLength(0)
  })

  it("asks to edit the last message on Up in an empty composer only", () => {
    let asked = 0
    const { controller } = setup({ onEditLast: () => (asked++, true) })
    expect(controller.handleKeyDown(key("ArrowUp"))).toBe(true)
    controller.insertText("x")
    expect(controller.handleKeyDown(key("ArrowUp"))).toBe(false)
    expect(asked).toBe(1)
  })

  it("formats, undoes and redoes from the keyboard", () => {
    const { controller } = setup({ platform: "other" })
    controller.insertText("ab")
    controller.handleKeyDown(key("b", { ctrlKey: true }))
    controller.insertText("c")
    expect(controller.doc.peek().entities).toEqual([{ type: "bold", offset: 2, length: 1 }])
    controller.handleKeyDown(key("z", { ctrlKey: true }))
    expect(controller.doc.peek().text).toBe("ab")
    controller.handleKeyDown(key("y", { ctrlKey: true }))
    expect(controller.doc.peek().text).toBe("abc")
  })

  it("routes autocomplete keys to the list, Escape dismisses, unhandled Enter sends", () => {
    const keys: string[] = []
    let handle = true
    const { sent, controller } = setup({
      onAutocompleteKey: (k) => {
        keys.push(k)
        return handle
      },
    })
    controller.insertText("hi @mo")
    expect(controller.autocomplete.peek()?.query).toBe("mo")
    controller.handleKeyDown(key("ArrowDown"))
    controller.handleKeyDown(key("Enter"))
    expect(keys).toEqual(["next", "accept"])
    expect(sent).toHaveLength(0)
    handle = false
    controller.handleKeyDown(key("Escape"))
    expect(controller.autocomplete.peek()).toBeNull()
    controller.insertText("x")
    expect(controller.autocomplete.peek()).toBeNull()
    controller.insertText(" @")
    expect(controller.autocomplete.peek()?.query).toBe("")
    controller.handleKeyDown(key("Enter"))
    expect(sent).toHaveLength(1)
  })
})

describe("autocomplete", () => {
  it("accepts a mention as an atom", () => {
    const { controller } = setup()
    controller.insertText("hey @mo")
    controller.acceptAutocomplete({ kind: "mention", atom: { type: "mention", userId: "7" as UserID }, label: "@Mo" })
    const doc = controller.doc.peek()
    expect(doc.text).toBe("hey @Mo ")
    expect(doc.entities).toEqual([{ type: "mention", offset: 4, length: 3, userId: "7" }])
    expect(controller.autocomplete.peek()).toBeNull()
  })

  it("accepts emoji and commands", () => {
    const { controller } = setup()
    controller.insertText("ok :thu")
    controller.acceptAutocomplete({ kind: "emoji", text: "👍" })
    expect(controller.doc.peek().text).toBe("ok 👍")
    const other = setup().controller
    other.insertText("/ren")
    other.acceptAutocomplete({ kind: "command", text: "rename" })
    expect(other.doc.peek().text).toBe("/rename ")
    expect(other.doc.peek().entities).toEqual([{ type: "botCommand", offset: 0, length: 7 }])
  })
})

describe("DOM read-back", () => {
  it("coalesces typed characters into one undo step and keeps entities", () => {
    const { controller } = setup({ initial: { text: "ab", entities: [{ type: "bold", offset: 0, length: 2 }], revision: 1 } })
    controller.setSelection(collapsed(1))
    controller.applyDomText("aXb", collapsed(2))
    controller.applyDomText("aXYb", collapsed(3))
    expect(controller.doc.peek().entities).toEqual([{ type: "bold", offset: 0, length: 4 }])
    expect(controller.lastChangeFromDom()).toBe(true)
    controller.undo()
    expect(controller.doc.peek().text).toBe("ab")
    expect(controller.doc.peek().selection).toEqual(collapsed(1))
  })

  it("uses the caret to place an ambiguous insertion", () => {
    const { controller } = setup({ initial: { text: "aa", entities: [{ type: "italic", offset: 1, length: 1 }], revision: 1 } })
    controller.setSelection(collapsed(1))
    controller.applyDomText("aaa", collapsed(2))
    // Typed at offset 1, the leading edge of the italic: not italic.
    expect(controller.doc.peek().entities).toEqual([{ type: "italic", offset: 2, length: 1 }])
  })

  it("applies the bold shortcut as its own step", () => {
    const { controller } = setup({ initial: { text: "**hi*", revision: 1 } })
    controller.applyDomText("**hi**", collapsed(6))
    expect(controller.doc.peek().text).toBe("hi")
    expect(controller.lastChangeFromDom()).toBe(false)
    controller.undo()
    expect(controller.doc.peek().text).toBe("**hi**")
  })
})

describe("paste and links", () => {
  it("pastes sanitized content as one step", () => {
    const { controller } = setup()
    controller.paste({ text: "a\r\nb" })
    expect(controller.doc.peek().text).toBe("a\nb")
    controller.undo()
    expect(controller.doc.peek().text).toBe("")
  })

  it("refuses links the policy refuses", () => {
    const { controller } = setup({ initial: { text: "x", revision: 1 } })
    controller.setSelection({ anchor: 0, focus: 1 })
    expect(controller.setLink("javascript:alert(1)")).toBe(false)
    expect(controller.setLink("https://ok.example")).toBe(true)
    expect(controller.doc.peek().entities[0]).toMatchObject({ type: "textUrl", url: "https://ok.example" })
  })

  it("moves dragged text inside the composer", () => {
    const { controller } = setup({ initial: { text: "one two three", revision: 1 } })
    controller.drop({ text: "two " }, 13, { from: 4, to: 8 })
    expect(controller.doc.peek().text).toBe("one threetwo ")
  })
})

describe("paste before the paste module arrives", () => {
  /** A stand-in paste module: HTML becomes bold "X" (the real one needs a DOM). */
  const fakeModule = (text = "X") =>
    ({ sanitizePaste: () => ({ text, entities: [{ type: "bold", offset: 0, length: text.length }] }) }) as unknown as PasteModule

  const lateSetup = (initial = "ab") => {
    const arrivals: ((module: PasteModule) => void)[] = []
    const failures: ((error: unknown) => void)[] = []
    const loads: number[] = []
    const ctx = setup({
      initial: { text: initial, revision: 1 },
      loadPaste: () => {
        loads.push(loads.length)
        return new Promise<PasteModule>((resolve, reject) => {
          arrivals.push(resolve)
          failures.push(reject)
        })
      },
    })
    return { ...ctx, arrivals, failures, loads }
  }

  it("pastes plain text and its own payloads at once, without loading the module", () => {
    const { controller, loads } = lateSetup("")
    controller.paste({ text: "plain", html: "<b>plain</b>" }, { plain: true })
    controller.paste({ internal: controller.clipboardPayload({ text: " @Mo", entities: [{ type: "mention", offset: 1, length: 3, userId: "1" as UserID }] }) })
    expect(controller.doc.peek().text).toBe("plain @Mo")
    expect(loads).toEqual([])
  })

  it("never drops or reorders keystrokes typed while it loads", async () => {
    const { controller, arrivals } = lateSetup("ab")
    controller.setSelection(collapsed(1))
    expect(controller.paste({ html: "<b>X</b>", text: "X" })).toBe(true)
    expect(controller.doc.peek().text).toBe("ab")
    for (const ch of "123") controller.insertText(ch)
    expect(controller.doc.peek().text).toBe("a123b")
    arrivals[0]!(fakeModule())
    await controller.latePastes()
    expect(controller.doc.peek().text).toBe("aX123b")
    expect(controller.doc.peek().entities).toEqual([{ type: "bold", offset: 1, length: 1 }])
    expect(controller.doc.peek().selection).toEqual(collapsed(5))
    // Typing goes on where the caret is; undo removes the paste as one step.
    controller.insertText("4")
    expect(controller.doc.peek().text).toBe("aX1234b")
  })

  it("keeps two pastes in the order they were made, a late one before a quick one after it", async () => {
    const { controller, arrivals } = lateSetup("")
    controller.paste({ html: "<b>X</b>", text: "X" })
    controller.paste({ text: "Y" })
    expect(controller.doc.peek().text).toBe("Y")
    arrivals[0]!(fakeModule())
    await controller.latePastes()
    expect(controller.doc.peek().text).toBe("XY")
  })

  it("inserts at the place a deletion before it moved", async () => {
    const { controller, arrivals } = lateSetup("hello world")
    controller.setSelection(collapsed(11))
    controller.paste({ html: "<b>X</b>", text: "X" })
    controller.setSelection(collapsed(5))
    controller.deleteBackward()
    expect(controller.doc.peek().text).toBe("hell world")
    arrivals[0]!(fakeModule("!"))
    await controller.latePastes()
    expect(controller.doc.peek().text).toBe("hell world!")
    expect(controller.doc.peek().selection).toEqual(collapsed(4))
  })

  it("falls back to the plain text when the module cannot load, and inserts nothing after dispose", async () => {
    const a = lateSetup("")
    a.controller.paste({ html: "<b>X</b>", text: "plain" })
    a.failures[0]!(new Error("offline"))
    await a.controller.latePastes()
    expect(a.controller.doc.peek().text).toBe("plain")

    const b = lateSetup("")
    b.controller.paste({ html: "<b>X</b>", text: "X" })
    b.controller.dispose()
    b.arrivals[0]!(fakeModule())
    await b.controller.latePastes()
    expect(b.controller.doc.peek().text).toBe("")
  })

  it("drops external HTML late at the drop point", async () => {
    const { controller, arrivals } = lateSetup("ab")
    controller.drop({ html: "<b>X</b>", text: "X" }, 2)
    controller.setSelection(collapsed(0))
    controller.insertText("0")
    arrivals[0]!(fakeModule())
    await controller.latePastes()
    expect(controller.doc.peek().text).toBe("0abX")
  })
})
