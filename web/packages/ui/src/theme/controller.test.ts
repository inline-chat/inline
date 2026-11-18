import { effect } from "@inline/reactive"
import { describe, expect, it } from "vitest"
import { appearanceCommands, APPEARANCE_COMMAND_IDS } from "./commands"
import { AppearanceController, ROOT_ATTRIBUTES, typographyVariables } from "./controller"
import { canvasColors } from "./palette"
import { DEFAULT_APPEARANCE_SETTINGS, parseAppearanceSettings, TEXT_SIZE_STEPS } from "./settings"
import { APPEARANCE_BOOT_KEY, APPEARANCE_STORAGE_KEY, memoryAppearanceStorage } from "./storage"
import { fakeBinding, fakeMatchMedia, fakeRoot } from "./testing"

const setup = (stored?: object, systemDark = false) => {
  const storage = memoryAppearanceStorage(stored ? { [APPEARANCE_STORAGE_KEY]: JSON.stringify(stored) } : {})
  const matchMedia = fakeMatchMedia(systemDark)
  const controller = new AppearanceController({ storage, binding: fakeBinding, matchMedia })
  const root = fakeRoot()
  return { storage, matchMedia, controller, root }
}

const stored = (storage: ReturnType<typeof memoryAppearanceStorage>) =>
  parseAppearanceSettings(storage.read(APPEARANCE_STORAGE_KEY))

describe("AppearanceController: applying to the root", () => {
  it("applies the stored settings on attach, before anything else runs", () => {
    const { controller, root } = setup({ version: 1, appearance: "dark", theme: "pink", sidebarItemSize: "standard" })
    controller.attach(root)
    expect([...root.classes].sort()).toEqual(
      ["density-standard", "group-color", "group-theme-color", "root-canvas", "scheme-dark", "theme-pink"].sort(),
    )
    expect(root.attributes.get(ROOT_ATTRIBUTES.appearance)).toBe("dark")
    expect(root.attributes.get(ROOT_ATTRIBUTES.resolvedAppearance)).toBe("dark")
    expect(root.attributes.get(ROOT_ATTRIBUTES.theme)).toBe("pink")
    expect(root.properties.size).toBe(0)
  })

  it("applies defaults when nothing is stored", () => {
    const { controller, root } = setup()
    controller.attach(root)
    expect(controller.settings.get()).toEqual(DEFAULT_APPEARANCE_SETTINGS)
    expect(root.classes.has("scheme-system")).toBe(true)
    expect(root.classes.has("theme-system")).toBe(true)
    expect(root.classes.has("density-standard")).toBe(false)
  })

  it("swaps classes in the same task as the setter and keeps classes it does not own", () => {
    const { controller, root } = setup()
    root.classList.add("app-owned")
    controller.attach(root)
    root.log.length = 0
    controller.setTheme("sunset")
    expect(root.log).toEqual(["-theme-system", "+theme-sunset", "@data-theme=sunset"])
    controller.setAppearance("light")
    expect(root.classes.has("scheme-system")).toBe(false)
    expect(root.classes.has("scheme-light")).toBe(true)
    expect(root.classes.has("app-owned")).toBe(true)
    // The class shared by every theme (StyleX's group class) stays on.
    expect(root.classes.has("group-color")).toBe(true)
  })

  it("follows the system when set to system, and only then", () => {
    const { controller, root, matchMedia } = setup()
    controller.attach(root)
    expect(controller.resolvedAppearance.get()).toBe("light")
    matchMedia.setDark(true)
    expect(controller.resolvedAppearance.get()).toBe("dark")
    expect(root.attributes.get(ROOT_ATTRIBUTES.resolvedAppearance)).toBe("dark")
    controller.setAppearance("light")
    expect(controller.resolvedAppearance.get()).toBe("light")
    matchMedia.setDark(false)
    matchMedia.setDark(true)
    expect(controller.resolvedAppearance.get()).toBe("light")
    expect(root.attributes.get(ROOT_ATTRIBUTES.resolvedAppearance)).toBe("light")
    controller.setAppearance("system")
    expect(controller.resolvedAppearance.get()).toBe("dark")
  })

  it("resolves system to light without matchMedia", () => {
    const controller = new AppearanceController({ storage: memoryAppearanceStorage(), binding: fakeBinding })
    expect(controller.resolvedAppearance.get()).toBe("light")
  })

  it("sets text size and line spacing as CSS variables and removes them at the defaults", () => {
    const { controller, root } = setup()
    controller.attach(root)
    controller.setTextSize(15)
    expect(root.properties.get("--message-font-size")).toBe("15px")
    expect(root.properties.get("--emoji-large")).toBe(`${Math.round((64 * 15 * 1000) / 13) / 1000}px`)
    controller.setLineSpacing(1.5)
    expect(root.properties.get("--message-line-height")).toBe("1.8")
    controller.resetTextSize()
    controller.setLineSpacing(1)
    expect(root.properties.size).toBe(0)
  })

  it("applies the monospace message font and standard sidebar as classes", () => {
    const { controller, root } = setup()
    controller.attach(root)
    controller.setMessageFont("monospace")
    controller.setSidebarItemSize("standard")
    expect(root.classes.has("font-mono")).toBe(true)
    expect(root.classes.has("density-standard")).toBe(true)
    controller.setMessageFont("system")
    expect(root.classes.has("font-mono")).toBe(false)
  })

  it("detach removes exactly what it added", () => {
    const { controller, root } = setup({ version: 1, theme: "ash", textSize: 18 })
    root.classList.add("app-owned")
    root.setAttribute("lang", "en")
    const detach = controller.attach(root)
    detach()
    expect([...root.classes]).toEqual(["app-owned"])
    expect([...root.attributes.keys()]).toEqual(["lang"])
    expect(root.properties.size).toBe(0)
    // Later changes no longer reach the element.
    controller.setTheme("pink")
    expect(root.classes.has("theme-pink")).toBe(false)
  })

  it("drives several roots (the document and a preview) and dispose detaches all", () => {
    const { controller, matchMedia } = setup()
    const a = fakeRoot()
    const b = fakeRoot()
    controller.attach(a)
    controller.attach(b)
    controller.setTheme("flexoki")
    expect(a.classes.has("theme-flexoki") && b.classes.has("theme-flexoki")).toBe(true)
    controller.dispose()
    expect(a.classes.size + b.classes.size).toBe(0)
    expect(matchMedia.listenerCount()).toBe(0)
    controller.setTheme("pink")
    expect(controller.theme.get()).toBe("flexoki")
  })

  it("removes the boot script's inline stand-ins once its classes are on", () => {
    const { controller, root } = setup({ version: 1, appearance: "dark" })
    root.style.setProperty("color-scheme", "dark")
    root.style.setProperty("background-color", "#1e1e1e")
    root.setAttribute(ROOT_ATTRIBUTES.boot, "dark")
    root.log.length = 0
    controller.attach(root)
    const classIndex = root.log.indexOf("+scheme-dark")
    const removeIndex = root.log.indexOf("color-scheme=")
    expect(classIndex).toBeGreaterThanOrEqual(0)
    expect(removeIndex).toBeGreaterThan(classIndex)
    expect(root.properties.size).toBe(0)
    expect(root.hasAttribute(ROOT_ATTRIBUTES.boot)).toBe(false)
  })

  it("does not touch inline color-scheme it did not get from the boot script", () => {
    const { controller, root } = setup()
    root.style.setProperty("color-scheme", "dark")
    controller.attach(root)
    expect(root.properties.get("color-scheme")).toBe("dark")
  })
})

describe("AppearanceController: settings and persistence", () => {
  it("persists every change in the same task", () => {
    const { controller, storage } = setup()
    controller.setTheme("midnight")
    expect(stored(storage).theme).toBe("midnight")
    controller.update({ compactToolbar: true, centeredChats: false, unreadBadgeStyle: "numbered", messageStyle: "minimal" })
    expect(stored(storage)).toMatchObject({
      compactToolbar: true,
      centeredChats: false,
      unreadBadgeStyle: "numbered",
      messageStyle: "minimal",
      version: 1,
    })
  })

  it("writes nothing and notifies nobody for a change to the same value", () => {
    const { controller, storage } = setup({ version: 1, theme: "pink" })
    let runs = 0
    const stop = effect(() => {
      controller.settings.get()
      runs += 1
    })
    const before = storage.read(APPEARANCE_STORAGE_KEY)
    controller.setTheme("pink")
    expect(runs).toBe(1)
    expect(storage.read(APPEARANCE_STORAGE_KEY)).toBe(before)
    stop()
  })

  it("field signals change only when their field does", () => {
    const { controller } = setup()
    let themeRuns = 0
    const stop = effect(() => {
      controller.theme.get()
      themeRuns += 1
    })
    controller.setTextSize(16)
    controller.setAppearance("dark")
    expect(themeRuns).toBe(1)
    controller.setTheme("ash")
    expect(themeRuns).toBe(2)
    stop()
  })

  it("ignores invalid values in an update field by field, keeping the current value", () => {
    const { controller } = setup({ version: 1, theme: "pink", appearance: "dark" })
    controller.update({ theme: "nope" as never, appearance: "sepia" as never, centeredChats: false })
    expect(controller.theme.get()).toBe("pink")
    expect(controller.appearance.get()).toBe("dark")
    expect(controller.centeredChats.get()).toBe(false)
    controller.setTextSize(Number.NaN)
    expect(controller.textSize.get()).toBe(13)
  })

  it("clamps text size and line spacing like the Mac app", () => {
    const { controller } = setup()
    controller.setTextSize(99)
    expect(controller.textSize.get()).toBe(32)
    controller.setTextSize(2)
    expect(controller.textSize.get()).toBe(10)
    controller.setLineSpacing(3)
    expect(controller.lineSpacing.get()).toBe(2)
    controller.setLineSpacing(0.5)
    expect(controller.lineSpacing.get()).toBe(1)
  })

  it("steps text size through the Mac app's steps, with limits and reset", () => {
    const { controller } = setup()
    const seen: number[] = [controller.textSize.get()]
    while (controller.increaseTextSize()) seen.push(controller.textSize.get())
    expect(seen).toEqual(TEXT_SIZE_STEPS.filter((s) => s >= 13))
    expect(controller.canIncreaseTextSize.get()).toBe(false)
    expect(controller.increaseTextSize()).toBe(false)
    controller.resetTextSize()
    expect(controller.textSize.get()).toBe(13)
    expect(controller.isDefaultTextSize.get()).toBe(true)
    const down: number[] = []
    while (controller.decreaseTextSize()) down.push(controller.textSize.get())
    expect(down).toEqual([12, 11, 10])
    expect(controller.canDecreaseTextSize.get()).toBe(false)
  })

  it("steps from an off-step size to the neighbouring steps", () => {
    const { controller } = setup({ version: 1, textSize: 19 })
    expect(controller.textSize.get()).toBe(19)
    controller.increaseTextSize()
    expect(controller.textSize.get()).toBe(20)
    controller.setTextSize(19)
    controller.decreaseTextSize()
    expect(controller.textSize.get()).toBe(18)
  })

  it("restores message text defaults and all defaults", () => {
    const { controller, storage } = setup({ version: 1, theme: "pastel", textSize: 20, lineSpacing: 1.3, messageFont: "monospace" })
    controller.resetMessageText()
    expect(controller.settings.get()).toMatchObject({ theme: "pastel", textSize: 13, lineSpacing: 1, messageFont: "system" })
    controller.reset()
    expect(controller.settings.get()).toEqual(DEFAULT_APPEARANCE_SETTINGS)
    expect(stored(storage)).toEqual(DEFAULT_APPEARANCE_SETTINGS)
  })

  it("reloads settings another tab wrote, without writing back", () => {
    const { controller, storage, root } = setup()
    controller.attach(root)
    const writes: string[] = []
    const original = storage.write
    storage.write = (key, value) => {
      writes.push(key)
      original(key, value)
    }
    storage.entries.set(APPEARANCE_STORAGE_KEY, JSON.stringify({ version: 1, theme: "neon-noir" }))
    controller.reload()
    expect(root.classes.has("theme-neon-noir")).toBe(true)
    expect(writes.filter((k) => k === APPEARANCE_STORAGE_KEY)).toEqual([])
  })

  it("survives storage that throws", () => {
    const controller = new AppearanceController({
      storage: {
        read: () => {
          throw new Error("blocked")
        },
        write: () => {
          throw new Error("blocked")
        },
      },
      binding: fakeBinding,
    })
    expect(controller.settings.get()).toEqual(DEFAULT_APPEARANCE_SETTINGS)
  })
})

describe("AppearanceController: boot record", () => {
  it("writes the appearance and the theme's window colors for the pre-paint script", () => {
    const { controller, storage } = setup()
    const record = () => JSON.parse(storage.read(APPEARANCE_BOOT_KEY) ?? "null")
    expect(record()).toEqual({ v: 1, a: "system", l: canvasColors("system").light, d: canvasColors("system").dark })
    controller.setTheme("midnight")
    controller.setAppearance("dark")
    expect(record()).toEqual({ v: 1, a: "dark", l: canvasColors("midnight").light, d: canvasColors("midnight").dark })
  })

  it("does not rewrite the boot record for unrelated changes", () => {
    const { controller, storage } = setup()
    const writes: string[] = []
    const original = storage.write
    storage.write = (key, value) => {
      writes.push(key)
      original(key, value)
    }
    controller.setTextSize(15)
    controller.setCenteredChats(false)
    expect(writes).toEqual([APPEARANCE_STORAGE_KEY, APPEARANCE_STORAGE_KEY])
  })

  it("can leave the boot record alone (preview controllers)", () => {
    const storage = memoryAppearanceStorage()
    new AppearanceController({ storage, binding: fakeBinding, writeBootRecord: false })
    expect(storage.read(APPEARANCE_BOOT_KEY)).toBeNull()
  })
})

describe("typographyVariables", () => {
  it("is empty at the defaults", () => {
    expect(Object.values(typographyVariables(13, 1)).every((v) => v === undefined)).toBe(true)
  })

  it("scales emoji with the text size like ChatTypography", () => {
    expect(typographyVariables(26, 1)).toMatchObject({ messageFontSize: "26px", emojiLarge: "128px", emojiMedium: "84px", emojiSmall: "36px" })
    expect(typographyVariables(13, 1.15).messageLineHeight).toBe("1.38")
  })
})

describe("appearance commands", () => {
  it("run the text size actions and track their enabled state", () => {
    const { controller } = setup({ version: 1, textSize: 28 })
    const commands = new Map(appearanceCommands(controller).map((c) => [c.id, c]))
    const increase = commands.get(APPEARANCE_COMMAND_IDS.textSizeIncrease)
    const reset = commands.get(APPEARANCE_COMMAND_IDS.textSizeReset)
    expect(increase?.enabled?.get()).toBe(true)
    increase?.run()
    expect(controller.textSize.get()).toBe(32)
    expect(increase?.enabled?.get()).toBe(false)
    expect(reset?.enabled?.get()).toBe(true)
    reset?.run()
    expect(controller.textSize.get()).toBe(13)
    expect(reset?.enabled?.get()).toBe(false)
  })

  it("leave the browser's zoom keys alone in a browser tab", () => {
    const { controller } = setup()
    for (const command of appearanceCommands(controller)) {
      if (command.shortcuts) expect(command.shortcuts.browser?.default).toEqual([])
    }
  })

  it("switch appearance", () => {
    const { controller } = setup()
    const commands = new Map(appearanceCommands(controller).map((c) => [c.id, c]))
    commands.get(APPEARANCE_COMMAND_IDS.appearanceDark)?.run()
    expect(controller.appearance.get()).toBe("dark")
    expect(commands.get(APPEARANCE_COMMAND_IDS.appearanceDark)?.enabled?.get()).toBe(false)
  })
})
