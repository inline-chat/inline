import { CommandRegistry, buildShortcutReference } from "@inline/view"
import { describe, expect, it } from "vitest"
import {
  filterShortcuts,
  formatBytes,
  formatUsage,
  keyCaps,
  permissionCopy,
  persistenceCopy,
  sendKeyDescription,
  sendKeyOptions,
  signOutWarning,
  spokenCombo,
  updateCopy,
} from "./format"

describe("formatBytes", () => {
  it("uses decimal units with Intl", () => {
    expect(formatBytes(0, "en-US")).toBe("0 bytes")
    expect(formatBytes(512, "en-US")).toBe("512 bytes")
    expect(formatBytes(1_500, "en-US")).toBe("1.5 kB")
    expect(formatBytes(12_345_678, "en-US")).toBe("12.3 MB")
    expect(formatBytes(250_000_000, "en-US")).toBe("250 MB")
    expect(formatBytes(3_000_000_000, "en-US")).toBe("3 GB")
  })

  it("treats invalid sizes as zero", () => {
    expect(formatBytes(Number.NaN, "en-US")).toBe("0 bytes")
    expect(formatBytes(-5, "en-US")).toBe("0 bytes")
  })

  it("localizes digits and separators", () => {
    expect(formatBytes(1_500_000, "de-DE")).toBe("1,5 MB")
  })

  it("states the quota when the browser gives one", () => {
    expect(formatUsage({ usage: 2_000_000, quota: 1_000_000_000 }, "en-US")).toBe("2 MB of 1 GB this browser allows")
    expect(formatUsage({ usage: 2_000_000, quota: 0 }, "en-US")).toBe("2 MB")
  })
})

describe("key caps", () => {
  it("splits Mac glyphs and other platforms' plus-joined names", () => {
    expect(keyCaps("⌘K", "mac")).toEqual(["⌘", "K"])
    expect(keyCaps("⌃⌥⇧⌘↑", "mac")).toEqual(["⌃", "⌥", "⇧", "⌘", "↑"])
    expect(keyCaps("Ctrl+Shift+E", "windows")).toEqual(["Ctrl", "Shift", "E"])
    expect(keyCaps("Ctrl++", "linux")).toEqual(["Ctrl", "+"])
    expect(keyCaps("Escape", "windows")).toEqual(["Escape"])
  })

  it("speaks Mac modifiers as words", () => {
    expect(spokenCombo("⌘⇧E", "mac")).toBe("Command Shift E")
    expect(spokenCombo("Ctrl+K", "windows")).toBe("Ctrl K")
  })
})

describe("filterShortcuts", () => {
  const registry = new CommandRegistry()
  registry.register({ id: "app.quickSearch", title: "Quick Search", category: "app", shortcuts: { default: "Mod+K" }, run: () => {} })
  registry.register({ id: "view.toggleSidebar", title: "Toggle Sidebar", category: "view", shortcuts: { default: "Mod+S" }, run: () => {} })
  registry.register({ id: "app.unbound", title: "Unbound Thing", category: "app", run: () => {} })
  const reference = buildShortcutReference(registry, { os: "mac", surface: "browser" })

  it("drops commands without a key here and empty categories", () => {
    const all = filterShortcuts(reference, "")
    expect(all.flatMap((category) => category.commands.map((command) => command.id))).toEqual([
      "app.quickSearch",
      "view.toggleSidebar",
    ])
  })

  it("matches title and category words by prefix, and key text", () => {
    expect(filterShortcuts(reference, "side").flatMap((c) => c.commands.map((command) => command.id))).toEqual([
      "view.toggleSidebar",
    ])
    expect(filterShortcuts(reference, "view").flatMap((c) => c.commands.map((command) => command.id))).toEqual([
      "view.toggleSidebar",
    ])
    expect(filterShortcuts(reference, "⌘k").flatMap((c) => c.commands.map((command) => command.id))).toEqual([
      "app.quickSearch",
    ])
    expect(filterShortcuts(reference, "nothing like this")).toEqual([])
  })
})

describe("copy", () => {
  it("says plainly what signing out erases, and counts unsent messages", () => {
    expect(signOutWarning(0)).toMatch(/stored on this device are erased/)
    expect(signOutWarning(0)).not.toMatch(/not been sent/)
    expect(signOutWarning(1)).toMatch(/1 message has not been sent yet and will be lost\.$/)
    expect(signOutWarning(3)).toMatch(/3 messages have not been sent yet/)
  })

  it("names the send keys in the platform's words", () => {
    expect(sendKeyOptions("mac").map((option) => option.label)).toEqual(["Return", "⌘ Return"])
    expect(sendKeyOptions("windows").map((option) => option.label)).toEqual(["Enter", "Ctrl+Enter"])
    expect(sendKeyDescription("modEnter", "linux")).toBe("Ctrl+Enter sends. Enter starts a new line.")
  })

  it("describes every permission state, and offers to ask only before a decision", () => {
    expect(permissionCopy("default", "web").canAsk).toBe(true)
    for (const state of ["granted", "denied", "unavailable"] as const) expect(permissionCopy(state, "web").canAsk).toBe(false)
    expect(permissionCopy("denied", "web").detail).toMatch(/site settings/)
    expect(permissionCopy("denied", "electron").detail).toMatch(/system settings/)
  })

  it("describes persistence and updates", () => {
    expect(persistenceCopy(true).status).toBe("Persistent")
    expect(persistenceCopy(false).detail).toMatch(/could be lost/)
    expect(persistenceCopy(null).status).toBe("Unknown")
    expect(updateCopy({ status: "ready", version: "1.2" })).toEqual({
      status: "Version 1.2 is ready. Reload to use it.",
      canApply: true,
    })
    expect(updateCopy({ status: "available" }).canApply).toBe(false)
    expect(updateCopy({ status: "none" }).canApply).toBe(false)
  })
})
