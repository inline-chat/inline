import { describe, expect, it } from "vitest"
import {
  directionForLocale,
  isLocale,
  landingPathForLocale,
  localeForLandingPath,
  localeFromPathSegment,
  resolveTheme,
} from "./preferences"

describe("public-beta landing preferences", () => {
  it("maps every locale to its canonical landing path", () => {
    expect(landingPathForLocale("en")).toBe("/beta")
    expect(landingPathForLocale("fa")).toBe("/beta/fa")
    expect(landingPathForLocale("zh-CN")).toBe("/beta/zh-cn")
  })

  it("resolves only supported localized landing paths", () => {
    expect(localeFromPathSegment("ZH-TW")).toBe("zh-TW")
    expect(localeForLandingPath("/beta")).toBe("en")
    expect(localeForLandingPath("/beta/")).toBe("en")
    expect(localeForLandingPath("/beta/fa")).toBe("fa")
    expect(localeForLandingPath("/beta/fa/")).toBe("fa")
    expect(localeForLandingPath("/")).toBeNull()
    expect(localeForLandingPath("/docs")).toBeNull()
    expect(localeForLandingPath("/beta/fa/extra")).toBeNull()
  })

  it("validates remembered locales and applies RTL only where needed", () => {
    expect(isLocale("fa")).toBe(true)
    expect(isLocale("unknown")).toBe(false)
    expect(directionForLocale("ar")).toBe("rtl")
    expect(directionForLocale("fa")).toBe("rtl")
    expect(directionForLocale("en")).toBe("ltr")
  })

  it("uses system for missing or unsupported theme preferences", () => {
    expect(resolveTheme("dark")).toBe("dark")
    expect(resolveTheme("light")).toBe("light")
    expect(resolveTheme("sepia")).toBe("system")
    expect(resolveTheme(null)).toBe("system")
  })
})
