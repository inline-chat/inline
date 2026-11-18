import { readFileSync } from "node:fs"
import { fileURLToPath } from "node:url"
import { describe, expect, it } from "vitest"
import { AppearanceController, ROOT_ATTRIBUTES } from "./controller"
import { canvasColors } from "./palette"
import { APPEARANCE_BOOT_KEY, memoryAppearanceStorage } from "./storage"
import { fakeBinding, fakeMatchMedia, fakeRoot, type FakeRoot } from "./testing"

const bootSource = readFileSync(fileURLToPath(new URL("./boot.js", import.meta.url)), "utf8")

/** Runs boot.js as the browser would (a classic script), against fakes for window and document. */
function runBoot(options: { record?: string | null; systemDark?: boolean; storageThrows?: boolean; root?: FakeRoot }) {
  const root = options.root ?? fakeRoot()
  const window = {
    localStorage: {
      getItem: (key: string) => {
        if (options.storageThrows) throw new Error("SecurityError")
        return key === APPEARANCE_BOOT_KEY ? (options.record ?? null) : null
      },
    },
    matchMedia: (query: string) => ({ matches: query === "(prefers-color-scheme: dark)" && !!options.systemDark }),
  }
  new Function("window", "document", bootSource)(window, { documentElement: root })
  return root
}

const record = (a: string, l = "#ffffff", d = "#1e1e1e") => JSON.stringify({ v: 1, a, l, d })

describe("boot.js", () => {
  it("is a classic script: no imports, no exports", () => {
    expect(bootSource).not.toMatch(/^\s*(import|export)\b/m)
    expect(bootSource.length).toBeLessThan(2000)
  })

  it("paints the chosen appearance and window color before the app runs", () => {
    const root = runBoot({ record: record("dark", "#ffffff", "#0d1117") })
    expect(root.properties.get("color-scheme")).toBe("dark")
    expect(root.properties.get("background-color")).toBe("#0d1117")
    expect(root.attributes.get(ROOT_ATTRIBUTES.boot)).toBe("dark")
  })

  it("resolves system with matchMedia", () => {
    expect(runBoot({ record: record("system"), systemDark: true }).properties.get("color-scheme")).toBe("dark")
    const light = runBoot({ record: record("system"), systemDark: false })
    expect(light.properties.get("color-scheme")).toBe("light")
    expect(light.properties.get("background-color")).toBe("#ffffff")
  })

  it("does nothing without a record, with a bad one, or without storage", () => {
    for (const options of [
      { record: null },
      { record: "{" },
      { record: JSON.stringify({ v: 2, a: "dark", l: "#fff", d: "#000" }) },
      { record: JSON.stringify({ v: 1, a: "sepia", l: "#ffffff", d: "#000000" }) },
      { storageThrows: true },
    ]) {
      const root = runBoot(options)
      expect(root.properties.size).toBe(0)
      expect(root.attributes.size).toBe(0)
    }
  })

  it("ignores a color that is not #rrggbb", () => {
    const root = runBoot({ record: record("light", "url(x)", "#000000") })
    expect(root.properties.get("color-scheme")).toBe("light")
    expect(root.properties.has("background-color")).toBe(false)
  })

  it("reads what the controller writes, and the controller then takes over", () => {
    const storage = memoryAppearanceStorage({ "inline.appearance": JSON.stringify({ version: 1, appearance: "dark", theme: "flexoki" }) })
    // First visit: the controller writes the boot record.
    const first = new AppearanceController({ storage, binding: fakeBinding, matchMedia: fakeMatchMedia() })
    first.dispose()

    // Next load: boot.js runs first, then the controller attaches.
    const root = runBoot({ record: storage.read(APPEARANCE_BOOT_KEY) })
    expect(root.properties.get("background-color")).toBe(canvasColors("flexoki").dark)
    const controller = new AppearanceController({ storage, binding: fakeBinding, matchMedia: fakeMatchMedia() })
    controller.attach(root)
    expect(root.classes.has("scheme-dark")).toBe(true)
    expect(root.properties.size).toBe(0)
    expect(root.hasAttribute(ROOT_ATTRIBUTES.boot)).toBe(false)
  })
})
