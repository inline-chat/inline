// @vitest-environment happy-dom
import { afterEach, describe, expect, test } from "vitest"
import { avatarPaletteIndex, avatarSeed, avatarStyle, initials } from "../avatar/avatar"
import { click, h, mount } from "../testing/dom"
import { ToggleController } from "./controller"

afterEach(() => document.body.replaceChildren())

describe("toggle", () => {
  test("a toggle button reflects aria-pressed and flips on click", () => {
    const changes: boolean[] = []
    const toggle = new ToggleController({ onChange: (pressed) => changes.push(pressed) })
    const button = mount(h("button", {}, "Bold"))
    toggle.root.attach(button)
    expect(button.getAttribute("aria-pressed")).toBe("false")
    click(button)
    expect(button.getAttribute("aria-pressed")).toBe("true")
    expect(button.getAttribute("data-state")).toBe("on")
    expect(changes).toEqual([true])
  })

  test("a switch uses role switch and aria-checked; disabled ignores clicks", () => {
    const toggle = new ToggleController({ kind: "switch", pressed: true })
    const button = mount(h("button", {}, "Notifications")) as HTMLButtonElement
    toggle.root.attach(button)
    expect(button.getAttribute("role")).toBe("switch")
    expect(button.getAttribute("aria-checked")).toBe("true")
    toggle.setDisabled(true)
    expect(button.disabled).toBe(true)
    toggle.toggle()
    expect(toggle.pressed.peek()).toBe(true)
  })
})

describe("avatar", () => {
  test("palette index matches the Apple apps (sum of UTF-8 bytes modulo 12)", () => {
    expect(avatarPaletteIndex("A")).toBe(65 % 12)
    expect(avatarPaletteIndex("Mo Rajabi")).toBe([..."Mo Rajabi"].reduce((sum, c) => sum + c.charCodeAt(0), 0) % 12)
    expect(avatarPaletteIndex("é")).toBe((0xc3 + 0xa9) % 12)
    expect(avatarStyle("A").background).toMatch(/^rgb\(/)
  })

  test("seed and initials", () => {
    expect(avatarSeed({ firstName: " Ada ", lastName: "Lovelace" })).toBe("Ada Lovelace")
    expect(avatarSeed({ email: "grace@example.com" })).toBe("grace")
    expect(avatarSeed({})).toBe("User")
    expect(initials("ada lovelace")).toBe("AL")
    expect(initials("Grace Brewster Hopper")).toBe("GH")
    expect(initials("👩🏽‍💻 Dev")).toBe("👩🏽‍💻D")
    expect(initials("  ")).toBe("")
  })
})
