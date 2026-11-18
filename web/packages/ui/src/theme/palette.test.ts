import { fileURLToPath } from "node:url"
import { describe, expect, it } from "vitest"
import { THEME_IDS, THEME_SEEDS } from "./catalog"
import { blend, contrastRatio, parseColor, splitLightDark, toHex, toHsb, fromHsb, composite } from "./color-math"
import { themeExportName } from "./generate"
import {
  accentStates,
  BASE_COLORS,
  canvasColors,
  FORCED_COLORS,
  resolveTheme,
  SHARED_COLOR_TOKENS,
  THEME_COLOR_TOKENS,
  THEMED_COLOR_TOKENS,
  themeValues,
} from "./palette"
import { type DeclaredValue, defaultValue, readStylexDeclarations } from "./stylex-source"

const src = (path: string) => fileURLToPath(new URL(`../${path}`, import.meta.url))
const colorTokens = readStylexDeclarations(src("tokens/color.stylex.ts")).color?.values ?? {}
const themeColorTokens = readStylexDeclarations(src("tokens/theme-color.stylex.ts")).themeColor?.values ?? {}
const themeModule = readStylexDeclarations(src("theme/themes.ts"))

const conditions = (value: DeclaredValue | undefined) =>
  value === undefined || typeof value === "string" ? [] : Object.keys(value).filter((k) => k !== "default")

describe("color math", () => {
  it("parses the token forms", () => {
    expect(parseColor("#0a84ff")).toEqual({ r: 10, g: 132, b: 255, a: 1 })
    expect(parseColor("rgb(0 0 0 / 0.85)")).toEqual({ r: 0, g: 0, b: 0, a: 0.85 })
    expect(parseColor("rgba(255, 255, 255, 0.5)")).toEqual({ r: 255, g: 255, b: 255, a: 0.5 })
    expect(splitLightDark("light-dark(rgb(0 0 0 / 0.5), #fff)")).toEqual({ light: "rgb(0 0 0 / 0.5)", dark: "#fff" })
    expect(() => parseColor("Highlight")).toThrow()
  })

  it("measures WCAG contrast", () => {
    expect(contrastRatio(parseColor("#000"), parseColor("#fff"))).toBeCloseTo(21, 5)
    expect(contrastRatio(parseColor("#777777"), parseColor("#ffffff"))).toBeCloseTo(4.48, 2)
    // Translucent text is composited onto its background first.
    expect(contrastRatio(parseColor("rgb(0 0 0 / 0.5)"), parseColor("#ffffff"))).toBeCloseTo(
      contrastRatio(composite(parseColor("rgb(0 0 0 / 0.5)"), parseColor("#fff")), parseColor("#fff")),
      6,
    )
  })

  it("round-trips HSB", () => {
    for (const hex of ["#00a7f8", "#fd4f7e", "#44494d", "#623be2"]) {
      expect(toHex(fromHsb(toHsb(parseColor(hex))))).toBe(hex)
    }
  })
})

describe("base token mirror", () => {
  it("BASE_COLORS matches color.stylex.ts", () => {
    for (const [token, value] of Object.entries(BASE_COLORS)) {
      expect(defaultValue(colorTokens[token]), token).toBe(value)
    }
  })

  it("the themed and shared lists partition the color token group", () => {
    const declared = Object.keys(colorTokens).sort()
    const listed = [...THEMED_COLOR_TOKENS, ...SHARED_COLOR_TOKENS].sort()
    expect(listed).toEqual(declared)
    expect(new Set(listed).size).toBe(listed.length)
  })

  it("color.stylex.ts carries the forced-colors mapping for its tokens", () => {
    for (const [token, system] of Object.entries(FORCED_COLORS)) {
      if (!(token in colorTokens)) continue
      const value = colorTokens[token]
      expect(typeof value === "object" && value["@media (forced-colors: active)"], token).toBe(system)
    }
  })

  it("translucent surfaces turn opaque under reduced transparency", () => {
    for (const token of ["menuBackground", "popoverBackground", "tooltipBackground"]) {
      const value = colorTokens[token]
      const opaque = typeof value === "object" ? value["@media (prefers-reduced-transparency: reduce)"] : undefined
      expect(opaque, token).toBeTypeOf("string")
      const { light, dark } = splitLightDark(opaque ?? "")
      expect(parseColor(light).a).toBe(1)
      expect(parseColor(dark).a).toBe(1)
    }
  })
})

describe("themes", () => {
  it("every theme defines every themed color token and every theme-color token, and nothing else", () => {
    for (const theme of THEME_IDS) {
      const name = themeExportName(theme)
      const colorTheme = themeModule[`${name}Color`]
      const themeColorTheme = themeModule[`${name}ThemeColor`]
      expect(colorTheme?.group, theme).toBe("color")
      expect(themeColorTheme?.group, theme).toBe("themeColor")
      expect(Object.keys(colorTheme?.values ?? {}).sort(), theme).toEqual([...THEMED_COLOR_TOKENS].sort())
      expect(Object.keys(themeColorTheme?.values ?? {}).sort(), theme).toEqual([...THEME_COLOR_TOKENS].sort())
      for (const value of Object.values({ ...colorTheme?.values, ...themeColorTheme?.values })) {
        expect(defaultValue(value), theme).toBeTruthy()
      }
    }
    expect(Object.keys(themeColorTokens).sort()).toEqual([...THEME_COLOR_TOKENS].sort())
  })

  it("no theme drops a condition the base token has (contrast, forced colors, transparency)", () => {
    for (const theme of THEME_IDS) {
      const name = themeExportName(theme)
      for (const [token, value] of Object.entries(themeModule[`${name}Color`]?.values ?? {})) {
        expect(conditions(value).sort(), `${theme} ${token}`).toEqual(conditions(colorTokens[token]).sort())
      }
      for (const [token, value] of Object.entries(themeModule[`${name}ThemeColor`]?.values ?? {})) {
        expect(conditions(value).sort(), `${theme} ${token}`).toEqual(conditions(themeColorTokens[token]).sort())
      }
    }
  })

  it("never opts out of forced colors", () => {
    for (const declared of Object.values(themeModule)) {
      expect(JSON.stringify(declared)).not.toMatch(/forced-color-adjust/)
    }
  })

  it("the System theme is the kit's tokens unchanged", () => {
    const system = themeValues("system")
    for (const token of THEMED_COLOR_TOKENS) {
      const ours = splitLightDark(defaultValue(system.color[token]) ?? "")
      const kit = splitLightDark(defaultValue(colorTokens[token]) ?? "")
      expect(parseColor(ours.light), token).toEqual(parseColor(kit.light))
      expect(parseColor(ours.dark), token).toEqual(parseColor(kit.dark))
    }
  })

  it("takes primary colors straight from ThemeCatalog", () => {
    for (const theme of THEME_IDS) {
      const resolved = resolveTheme(theme)
      for (const variant of ["light", "dark"] as const) {
        const primary = THEME_SEEDS[theme][variant].primary.toLowerCase()
        expect(toHex(resolved[variant].accent)).toBe(primary)
        expect(toHex(resolved[variant].bubble)).toBe(primary)
        expect(toHex(resolved[variant].prominent)).toBe(primary)
      }
    }
  })

  it("derives surfaces with the Mac formulas", () => {
    // Midnight dark: #1e1e1e blended 8.4% toward #0D1117.
    expect(canvasColors("midnight")).toEqual({ light: "#ffffff", dark: "#1d1d1d" })
    // Pink: the canvas seed tints the window very slightly, as on the Mac.
    const pink = resolveTheme("pink")
    expect(toHex(pink.light.windowBackground)).toBe(toHex(blend(parseColor("#ffffff"), parseColor("#FFF5F7"), 0.056)))
    // Sidebar: the accent at 4.2% over the dark sidebar.
    expect(toHex(pink.dark.sidebarBackground)).toBe("#2c252a")
    // Reply pane: 2.5% toward black (light) from the window color.
    expect(toHex(pink.light.replyPaneBackground)).toBe(toHex(blend(pink.light.windowBackground, parseColor("#000"), 0.025)))
    // Secondary bubbles: #ECECEC only for System light.
    expect(toHex(resolveTheme("system").light.secondaryBubble)).toBe("#ececec")
    expect(toHex(resolveTheme("ash").light.secondaryBubble)).toBe("#eaeaea")
    expect(toHex(resolveTheme("ash").dark.secondaryBubble)).toBe("#2e2e2e")
  })

  it("the hover and pressed rule reproduces the kit's System accents exactly", () => {
    for (const variant of ["light", "dark"] as const) {
      const states = accentStates(parseColor(THEME_SEEDS.system[variant].primary), variant)
      const hover = splitLightDark(BASE_COLORS.accentHover)[variant]
      const pressed = splitLightDark(BASE_COLORS.accentPressed)[variant]
      expect(toHex(states.hover)).toBe(hover)
      expect(toHex(states.pressed)).toBe(pressed)
    }
  })

  it("bubble link follows resolvedSecondaryBubbleLinkColor", () => {
    // Light caps brightness at 0.88: System cyan gets a little darker, Sunset is already below.
    const system = resolveTheme("system")
    expect(toHsb(system.light.secondaryBubbleLink).b).toBeCloseTo(0.88, 2)
    expect(toHex(resolveTheme("sunset").light.secondaryBubbleLink)).toBe("#c94d24")
    // Dark keeps the hue, 48% of the saturation, brightness at least 0.9.
    const dark = toHsb(resolveTheme("pastel").dark.secondaryBubbleLink)
    const primary = toHsb(parseColor("#7D57C1"))
    expect(dark.h).toBeCloseTo(primary.h, 2)
    expect(dark.s).toBeCloseTo(primary.s * 0.48, 2)
    expect(Math.abs(dark.b - 0.9)).toBeLessThan(1 / 255 + 0.005)
  })
})
