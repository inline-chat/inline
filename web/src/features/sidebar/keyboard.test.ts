import { describe, expect, it } from "vitest"
import { listKeyAction, moveIndex, openIntentFor, pointerOpenIntent } from "./keyboard"

const mac = { os: "mac" as const, typeaheadActive: false }
const win = { os: "windows" as const, typeaheadActive: false }

describe("openIntentFor", () => {
  it("maps the platform modifier to a new tab and Option or Alt to the other pane", () => {
    expect(openIntentFor({}, "mac")).toBe("here")
    expect(openIntentFor({ metaKey: true }, "mac")).toBe("newTab")
    expect(openIntentFor({ ctrlKey: true }, "mac")).toBe("here")
    expect(openIntentFor({ ctrlKey: true }, "windows")).toBe("newTab")
    expect(openIntentFor({ metaKey: true }, "linux")).toBe("here")
    expect(openIntentFor({ altKey: true }, "mac")).toBe("otherPane")
    expect(openIntentFor({ metaKey: true, altKey: true }, "mac")).toBe("newPane")
    expect(openIntentFor({ shiftKey: true }, "mac")).toBe("here")
  })

  it("opens a new tab on middle click and ignores other buttons", () => {
    expect(pointerOpenIntent({ button: 1 }, "mac")).toBe("newTab")
    expect(pointerOpenIntent({ button: 0, metaKey: true }, "mac")).toBe("newTab")
    expect(pointerOpenIntent({ button: 2 }, "mac")).toBeUndefined()
    expect(pointerOpenIntent({ button: 0 }, "mac", () => "newWindow")).toBe("newWindow")
  })
})

describe("listKeyAction", () => {
  it("moves with plain arrows, Home, End and the page keys", () => {
    expect(listKeyAction({ key: "ArrowDown" }, mac)).toEqual({ kind: "move", to: "next" })
    expect(listKeyAction({ key: "ArrowUp" }, mac)).toEqual({ kind: "move", to: "previous" })
    expect(listKeyAction({ key: "Home" }, mac)).toEqual({ kind: "move", to: "first" })
    expect(listKeyAction({ key: "End" }, mac)).toEqual({ kind: "move", to: "last" })
    expect(listKeyAction({ key: "PageDown" }, mac)).toEqual({ kind: "move", to: "pageDown" })
  })

  it("leaves modified arrows to the app (Alt+Down is next chat; Shift is range selection later)", () => {
    expect(listKeyAction({ key: "ArrowDown", altKey: true }, mac)).toBeUndefined()
    expect(listKeyAction({ key: "ArrowDown", metaKey: true }, mac)).toBeUndefined()
    expect(listKeyAction({ key: "ArrowDown", shiftKey: true }, mac)).toBeUndefined()
  })

  it("opens with Enter and Space, with the modifier's intent", () => {
    expect(listKeyAction({ key: "Enter" }, mac)).toEqual({ kind: "open", intent: "here" })
    expect(listKeyAction({ key: "Enter", metaKey: true }, mac)).toEqual({ kind: "open", intent: "newTab" })
    expect(listKeyAction({ key: "Enter", ctrlKey: true }, win)).toEqual({ kind: "open", intent: "newTab" })
    expect(listKeyAction({ key: " " }, mac)).toEqual({ kind: "open", intent: "here" })
  })

  it("types characters, and Space while a search is running", () => {
    expect(listKeyAction({ key: "a" }, mac)).toEqual({ kind: "type", char: "a" })
    expect(listKeyAction({ key: "ل" }, mac)).toEqual({ kind: "type", char: "ل" })
    expect(listKeyAction({ key: "😀" }, mac)).toEqual({ kind: "type", char: "😀" })
    expect(listKeyAction({ key: " " }, { ...mac, typeaheadActive: true })).toEqual({ kind: "type", char: " " })
    expect(listKeyAction({ key: "k", metaKey: true }, mac)).toBeUndefined()
    expect(listKeyAction({ key: "Tab" }, mac)).toBeUndefined()
    expect(listKeyAction({ key: "Escape" }, mac)).toBeUndefined()
    expect(listKeyAction({ key: "F2" }, mac)).toBeUndefined()
    expect(listKeyAction({ key: "a", isComposing: true }, mac)).toBeUndefined()
  })
})

describe("moveIndex", () => {
  it("clamps at the ends without wrapping", () => {
    expect(moveIndex("next", 9, 10, 5)).toBe(9)
    expect(moveIndex("previous", 0, 10, 5)).toBe(0)
    expect(moveIndex("pageDown", 7, 10, 5)).toBe(9)
    expect(moveIndex("pageUp", 3, 10, 5)).toBe(0)
    expect(moveIndex("last", 0, 10, 5)).toBe(9)
  })

  it("starts at an end when nothing is current", () => {
    expect(moveIndex("next", -1, 10, 5)).toBe(0)
    expect(moveIndex("previous", -1, 10, 5)).toBe(9)
    expect(moveIndex("next", -1, 0, 5)).toBe(-1)
  })
})
