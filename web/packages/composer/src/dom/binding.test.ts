// @vitest-environment happy-dom
import type { UserID } from "@inline/ids"
import { manualTime } from "@inline/reactive"
import { afterEach, describe, expect, it } from "vitest"
import { createComposerController, type ComposerOptions, type SendRequest } from "../controller"
import { collapsed, docLines, type ComposerEntity } from "../model"
import { loadPasteModule, type PasteModule } from "../clipboard"
import { INTERNAL_MIME } from "../internal"
import { attachComposer } from "./binding"
import { domPointToOffset, offsetToDomPoint, readDomText } from "./selection"

const safeUrl = (url: string) => (/^https?:\/\//.test(url) ? url : null)
const user = "42" as UserID

const cleanups: (() => void)[] = []
afterEach(() => {
  while (cleanups.length) cleanups.pop()!()
  document.body.replaceChildren()
})

const mount = (
  initial: { text: string; entities?: ComposerEntity[] } = { text: "" },
  overrides: Partial<ComposerOptions> = {},
) => {
  const time = manualTime()
  const sent: SendRequest[] = []
  const saves: string[] = []
  const files: File[][] = []
  const controller = createComposerController({
    clock: time,
    safeUrl,
    send: (request) => {
      sent.push(request)
      return { status: "accepted" }
    },
    saveDraft: (text) => saves.push(text),
    onFiles: (f) => files.push([...f]),
    initial: { ...initial, revision: 1 },
    ...overrides,
  })
  const root = document.createElement("div")
  document.body.appendChild(root)
  const detach = attachComposer(root, controller, {
    classNames: { bold: "b-class", mention: "m-class", atom: "atom-class", line: "line-class" },
    placeholder: "Message",
  })
  cleanups.push(detach)
  root.focus()
  return { root, controller, sent, saves, files, time, detach }
}

const lines = (root: HTMLElement) => [...root.children] as HTMLElement[]

const setCaret = (node: Node, offset: number) => {
  document.getSelection()!.setBaseAndExtent(node, offset, node, offset)
}

const fire = (target: EventTarget, event: Event) => {
  target.dispatchEvent(event)
  return event.defaultPrevented
}

const beforeInput = (inputType: string, data?: string) =>
  new InputEvent("beforeinput", { inputType, data: data ?? null, bubbles: true, cancelable: true })

const key = (k: string, init: KeyboardEventInit = {}) =>
  new KeyboardEvent("keydown", { key: k, bubbles: true, cancelable: true, ...init })

const rich = () => ({
  text: "hello bold @Mo\n\nend",
  entities: [
    { type: "bold", offset: 6, length: 4 },
    { type: "mention", offset: 11, length: 3, userId: user },
  ] as ComposerEntity[],
})

describe("rendering", () => {
  it("renders one block per line with marks, atoms and fillers, using text nodes only", () => {
    const { root } = mount(rich())
    expect(root.getAttribute("contenteditable")).toBe("true")
    expect(root.getAttribute("role")).toBe("textbox")
    const [first, empty, last] = lines(root)
    expect(lines(root)).toHaveLength(3)
    for (const line of lines(root)) {
      expect(line.getAttribute("dir")).toBe("auto")
      expect(line.classList.contains("line-class")).toBe(true)
    }
    const nodes = [...first!.childNodes]
    expect(nodes.map((n) => n.nodeName)).toEqual(["#text", "SPAN", "#text", "SPAN", "BR"])
    const bold = nodes[1] as HTMLElement
    expect(bold.getAttribute("data-marks")).toBe("bold")
    expect(bold.classList.contains("b-class")).toBe(true)
    const atom = nodes[3] as HTMLElement
    expect(atom.getAttribute("contenteditable")).toBe("false")
    expect(atom.textContent).toBe("@Mo")
    expect(atom.className).toBe("atom-class m-class")
    expect([...empty!.childNodes].map((n) => n.nodeName)).toEqual(["BR"])
    expect(last!.textContent).toBe("end")
    expect(readDomText(root)).toBe(rich().text)
  })

  it("puts markup in the text as text", () => {
    const { root } = mount({ text: '<img src=x onerror="globalThis.__composerPwned = 1"><b>x</b>' })
    expect(root.querySelector("img")).toBeNull()
    expect(root.querySelector("b")).toBeNull()
    expect(root.textContent).toContain("<img")
    expect((globalThis as { __composerPwned?: unknown }).__composerPwned).toBeUndefined()
  })

  it("marks the empty state for the placeholder", () => {
    const { root, controller } = mount()
    expect(root.hasAttribute("data-empty")).toBe(true)
    expect(root.getAttribute("data-placeholder")).toBe("Message")
    controller.insertText("x")
    expect(root.hasAttribute("data-empty")).toBe(false)
  })

  it("touches only the changed line", () => {
    const { root, controller } = mount({ text: "one\ntwo\nthree" })
    const before = lines(root)
    const firstText = before[0]!.firstChild
    const lastText = before[2]!.firstChild
    controller.setSelection(collapsed(7))
    controller.insertText("!")
    const after = lines(root)
    expect(after).toEqual(before)
    expect(after[0]!.firstChild).toBe(firstText)
    expect(after[2]!.firstChild).toBe(lastText)
    expect(after[1]!.textContent).toBe("two!")
  })

  it("inserts and removes line elements for Enter and joins", () => {
    const { root, controller } = mount({ text: "ab\ncd" })
    const [a, c] = lines(root)
    controller.setSelection(collapsed(1))
    controller.insertLineBreak()
    expect(lines(root).map((l) => l.textContent)).toEqual(["a", "b", "cd"])
    expect(lines(root)[2]).toBe(c)
    expect(lines(root)[0]).toBe(a)
    controller.undo()
    expect(lines(root).map((l) => l.textContent)).toEqual(["ab", "cd"])
  })
})

describe("selection mapping", () => {
  it("maps every model offset to the DOM and back", () => {
    const { root, controller } = mount(rich())
    const text = controller.doc.peek().text
    for (let offset = 0; offset <= text.length; offset++) {
      if (offset > 11 && offset < 14) continue // inside the atom
      const point = offsetToDomPoint(root, offset)
      expect(domPointToOffset(root, point.node, point.offset)).toBe(offset)
    }
  })

  it("snaps points inside an atom to its edges", () => {
    const { root } = mount(rich())
    const atom = root.querySelector("[data-atom]")!
    expect(domPointToOffset(root, atom.firstChild!, 0)).toBe(11)
    expect(domPointToOffset(root, atom.firstChild!, 2)).toBe(14)
  })

  it("prefers plain text at a mark boundary so typing is not formatted", () => {
    const { root } = mount({ text: "abcd", entities: [{ type: "bold", offset: 0, length: 2 }] })
    const point = offsetToDomPoint(root, 2)
    expect(point.node.nodeType).toBe(3)
    expect(point.node.parentElement?.hasAttribute("data-marks")).toBe(false)
    expect(point.offset).toBe(0)
  })

  it("maps root-level and line-level element points", () => {
    const { root } = mount({ text: "ab\n\ncd" })
    expect(domPointToOffset(root, root, 0)).toBe(0)
    expect(domPointToOffset(root, root, 2)).toBe(4)
    expect(domPointToOffset(root, root, 3)).toBe(6)
    expect(domPointToOffset(root, lines(root)[1]!, 0)).toBe(3)
    expect(domPointToOffset(root, document.body, 0)).toBeNull()
  })

  it("puts the DOM caret where the model says after an edit", () => {
    const { root, controller } = mount({ text: "ab" })
    controller.setSelection(collapsed(1))
    controller.insertText("X")
    const selection = document.getSelection()!
    expect(domPointToOffset(root, selection.focusNode!, selection.focusOffset)).toBe(2)
  })
})

describe("read-back of browser typing", () => {
  it("reads typed text back into the model without touching the DOM", () => {
    const { root, controller } = mount({ text: "abcd", entities: [{ type: "bold", offset: 1, length: 2 }] })
    const span = root.querySelector("[data-marks]")!
    const text = span.firstChild as Text
    text.data = "bXc"
    setCaret(text, 2)
    fire(root, new Event("input", { bubbles: true }))
    expect(controller.doc.peek().text).toBe("abXcd")
    expect(controller.doc.peek().entities).toEqual([{ type: "bold", offset: 1, length: 3 }])
    expect(span.firstChild).toBe(text)
  })

  it("re-renders a line the browser formatted differently from the model", () => {
    const { root, controller } = mount({ text: "ab", entities: [{ type: "bold", offset: 0, length: 2 }] })
    const text = root.querySelector("[data-marks]")!.firstChild as Text
    // The browser typed at the trailing edge, into the bold span.
    text.data = "abX"
    setCaret(text, 3)
    fire(root, new Event("input", { bubbles: true }))
    expect(controller.doc.peek().text).toBe("abX")
    expect(controller.doc.peek().entities).toEqual([{ type: "bold", offset: 0, length: 2 }])
    const nodes = [...lines(root)[0]!.childNodes]
    expect(nodes.map((n) => n.textContent)).toEqual(["ab", "X"])
    expect(nodes[1]!.nodeType).toBe(3)
  })

  it("reads browser-made lines and loose text", () => {
    const { root, controller } = mount({ text: "ab" })
    const extra = document.createElement("div")
    extra.textContent = "new line"
    root.appendChild(extra)
    root.appendChild(document.createTextNode("loose"))
    fire(root, new Event("input", { bubbles: true }))
    expect(controller.doc.peek().text).toBe("ab\nnew line\nloose")
    expect(lines(root)).toHaveLength(3)
    expect([...root.childNodes].every((n) => (n as Element).hasAttribute?.("data-line"))).toBe(true)
  })

  it("leaves a composition alone until it ends", () => {
    const { root, controller } = mount({ text: "a" })
    const text = lines(root)[0]!.firstChild as Text
    fire(root, new CompositionEvent("compositionstart", { bubbles: true }))
    text.data = "aにほ"
    setCaret(text, 3)
    fire(root, new Event("input", { bubbles: true }))
    expect(controller.doc.peek().text).toBe("a")
    // A model change during the composition is not rendered yet.
    expect(fire(root, key("Enter", { isComposing: true }))).toBe(false)
    text.data = "a日本"
    setCaret(text, 3)
    fire(root, new CompositionEvent("compositionend", { bubbles: true, data: "日本" }))
    expect(controller.doc.peek().text).toBe("a日本")
    expect(controller.doc.peek().selection).toEqual(collapsed(3))
  })
})

describe("beforeinput routing", () => {
  it("takes Enter, formatting, undo and redo through the model", () => {
    const { root, controller } = mount({ text: "word" })
    setCaret(lines(root)[0]!.firstChild!, 2)
    expect(fire(root, beforeInput("insertParagraph"))).toBe(true)
    expect(controller.doc.peek().text).toBe("wo\nrd")
    expect(lines(root)).toHaveLength(2)
    expect(fire(root, beforeInput("historyUndo"))).toBe(true)
    expect(controller.doc.peek().text).toBe("word")
    expect(fire(root, beforeInput("historyRedo"))).toBe(true)
    expect(controller.doc.peek().text).toBe("wo\nrd")
    const first = lines(root)[0]!.firstChild!
    document.getSelection()!.setBaseAndExtent(first, 0, first, 2)
    expect(fire(root, beforeInput("formatBold"))).toBe(true)
    expect(controller.doc.peek().entities).toEqual([{ type: "bold", offset: 0, length: 2 }])
    expect(fire(root, beforeInput("formatJustifyCenter"))).toBe(true)
  })

  it("deletes an atom as a unit, and leaves plain deletion to the browser", () => {
    const { root, controller } = mount(rich())
    const after = lines(root)[0]!
    // Caret right after the atom: between the atom span and the filler.
    setCaret(after, 4)
    expect(fire(root, beforeInput("deleteContentBackward"))).toBe(true)
    expect(controller.doc.peek().text).toBe("hello bold \n\nend")
    expect(controller.doc.peek().entities.some((e) => e.type === "mention")).toBe(false)
    setCaret(lines(root)[2]!.firstChild!, 2)
    expect(fire(root, beforeInput("deleteContentBackward"))).toBe(false)
  })

  it("joins lines through the model", () => {
    const { root, controller } = mount({ text: "ab\ncd" })
    setCaret(lines(root)[1]!.firstChild!, 0)
    expect(fire(root, beforeInput("deleteContentBackward"))).toBe(true)
    expect(controller.doc.peek().text).toBe("abcd")
    expect(lines(root)).toHaveLength(1)
  })

  it("types through the model when a mark is pending", () => {
    const { root, controller } = mount({ text: "ab" })
    setCaret(lines(root)[0]!.firstChild!, 2)
    controller.toggleMark("bold")
    expect(fire(root, beforeInput("insertText", "c"))).toBe(true)
    expect(controller.doc.peek().entities).toEqual([{ type: "bold", offset: 2, length: 1 }])
    expect(root.querySelector("[data-marks]")?.textContent).toBe("c")
  })

  it("never lets the browser insert pasted or dropped HTML", () => {
    const { root } = mount()
    expect(fire(root, beforeInput("insertFromPaste"))).toBe(true)
    expect(fire(root, beforeInput("insertFromDrop"))).toBe(true)
  })
})

describe("keys", () => {
  it("sends on Enter and inserts a line on Shift+Enter", async () => {
    const { root, controller, sent } = mount({ text: "hi" })
    setCaret(lines(root)[0]!.firstChild!, 2)
    expect(fire(root, key("Enter", { shiftKey: true }))).toBe(true)
    expect(controller.doc.peek().text).toBe("hi\n")
    expect(fire(root, key("Enter"))).toBe(true)
    await Promise.resolve()
    expect(sent.map((s) => s.text)).toEqual(["hi"])
    expect(controller.doc.peek().text).toBe("")
    expect(lines(root)).toHaveLength(1)
  })

  it("ignores keys during composition and plain letters", () => {
    const { root } = mount({ text: "x" })
    expect(fire(root, key("Enter", { isComposing: true }))).toBe(false)
    expect(fire(root, key("Enter", { keyCode: 229 } as KeyboardEventInit))).toBe(false)
    expect(fire(root, key("a"))).toBe(false)
  })

  it("stops handling events after detach", () => {
    const { root, controller, detach } = mount({ text: "x" })
    detach()
    expect(fire(root, key("Enter", { shiftKey: true }))).toBe(false)
    expect(controller.doc.peek().text).toBe("x")
  })
})

describe("clipboard", () => {
  const clipboard = (type: string, data: Record<string, string>, files: File[] = []) => {
    const transfer = new DataTransfer()
    for (const [format, value] of Object.entries(data)) transfer.setData(format, value)
    for (const file of files) transfer.items.add(file)
    return new ClipboardEvent(type, { clipboardData: transfer, bubbles: true, cancelable: true })
  }

  it("pastes sanitized HTML at the caret", async () => {
    await loadPasteModule()
    const { root, controller } = mount({ text: "ab" })
    setCaret(lines(root)[0]!.firstChild!, 1)
    const event = clipboard("paste", { "text/html": "<b>X</b><script>1</script>", "text/plain": "X" })
    expect(fire(root, event)).toBe(true)
    expect(controller.doc.peek().text).toBe("aXb")
    expect(controller.doc.peek().entities).toEqual([{ type: "bold", offset: 1, length: 1 }])
    expect(root.querySelector("script")).toBeNull()
  })

  it("reads an HTML paste inside the event and inserts it when the paste module arrives, before what was typed meanwhile", async () => {
    let arrive!: (module: PasteModule) => void
    const loadPaste = () => new Promise<PasteModule>((resolve) => (arrive = resolve))
    const { root, controller } = mount({ text: "ab" }, { loadPaste })
    setCaret(lines(root)[0]!.firstChild!, 1)
    const event = clipboard("paste", { "text/html": "<b>X</b>", "text/plain": "X" })
    expect(fire(root, event)).toBe(true)
    // The event is over; its DataTransfer is gone. Nothing was inserted yet.
    event.clipboardData!.clearData()
    expect(controller.doc.peek().text).toBe("ab")
    expect(controller.hasLatePaste()).toBe(true)
    // The user types at the caret, through the browser (read back from the DOM).
    const text = lines(root)[0]!.firstChild!
    text.nodeValue = "ayzb"
    setCaret(text, 3)
    fire(root, new InputEvent("input", { inputType: "insertText", data: "z", bubbles: true }))
    expect(controller.doc.peek().text).toBe("ayzb")
    arrive(await import("../paste"))
    await controller.latePastes()
    expect(controller.doc.peek().text).toBe("aXyzb")
    expect(controller.doc.peek().entities).toEqual([{ type: "bold", offset: 1, length: 1 }])
    // The caret stays after what was typed.
    expect(controller.doc.peek().selection).toEqual({ anchor: 4, focus: 4 })
    expect(readDomText(root)).toBe("aXyzb")
  })

  it("round-trips a copy with a mention through paste", () => {
    const { root, controller } = mount(rich())
    const first = lines(root)[0]!
    document.getSelection()!.setBaseAndExtent(first.childNodes[1]!.firstChild!, 0, first, 4)
    const copy = clipboard("copy", {})
    fire(root, copy)
    const data = { "text/plain": copy.clipboardData!.getData("text/plain"), [INTERNAL_MIME]: copy.clipboardData!.getData(INTERNAL_MIME) }
    controller.setDraft({ text: "", revision: 9 })
    fire(root, clipboard("paste", data))
    expect(controller.doc.peek().entities.map((e) => e.type)).toEqual(["bold", "mention"])
  })

  it("pastes plain text after Mod+Shift+V", () => {
    const { root, controller } = mount({ text: "" }, { platform: "other" })
    fire(root, key("V", { ctrlKey: true, shiftKey: true }))
    fire(root, clipboard("paste", { "text/html": "<b>X</b>", "text/plain": "X" }))
    expect(controller.doc.peek().entities).toEqual([])
  })

  it("hands pasted files to the attachment hook", () => {
    const { root, files } = mount()
    fire(root, clipboard("paste", {}, [new File(["x"], "a.png", { type: "image/png" })]))
    expect(files.map((f) => f.map((x) => x.name))).toEqual([["a.png"]])
  })

  it("pastes the file when an image copied from a page comes with HTML and no text", () => {
    const { root, controller, files } = mount()
    const image = new File(["x"], "image.png", { type: "image/png" })
    fire(root, clipboard("paste", { "text/html": '<img src="https://example.test/a.png">' }, [image]))
    expect(files.map((f) => f.map((x) => x.name))).toEqual([["image.png"]])
    expect(controller.doc.peek().text).toBe("")
  })

  it("pastes the text when a document selection comes with a picture of itself", () => {
    const { root, controller, files } = mount()
    const picture = new File(["x"], "selection.png", { type: "image/png" })
    fire(root, clipboard("paste", { "text/html": "<table><tr><td>A1</td></tr></table>", "text/plain": "A1" }, [picture]))
    expect(files).toEqual([])
    expect(controller.doc.peek().text).toBe("A1")
  })

  it("copies the selection as text and as the internal format", () => {
    const { root } = mount(rich())
    const first = lines(root)[0]!
    document.getSelection()!.setBaseAndExtent(first.childNodes[1]!.firstChild!, 0, first, 4)
    const event = clipboard("copy", {})
    expect(fire(root, event)).toBe(true)
    expect(event.clipboardData!.getData("text/plain")).toBe("bold @Mo")
    const payload = JSON.parse(event.clipboardData!.getData(INTERNAL_MIME)) as { v: number; body: string; mac: string }
    expect(payload.v).toBe(2)
    expect(payload.mac).toMatch(/^[0-9a-f]{64}$/)
    expect(JSON.parse(payload.body)).toMatchObject({
      v: 1,
      text: "bold @Mo",
      entities: [{ type: "bold", offset: 0, length: 4 }, { type: "mention", offset: 5, length: 3 }],
    })
  })
})

describe("drafts on hide", () => {
  it("flushes the pending draft on pagehide", () => {
    const { controller, saves } = mount()
    controller.insertText("keep")
    window.dispatchEvent(new Event("pagehide"))
    expect(saves).toEqual(["keep"])
  })
})

describe("render model agreement", () => {
  it("renders exactly what docLines describes", () => {
    const { root, controller } = mount(rich())
    const model = docLines(controller.doc.peek())
    expect(lines(root).map((l) => l.textContent)).toEqual(model.map((l) => l.text))
  })
})
