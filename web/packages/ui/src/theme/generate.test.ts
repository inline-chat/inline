import { readFileSync, writeFileSync } from "node:fs"
import { fileURLToPath } from "node:url"
import { describe, expect, it } from "vitest"
import {
  GENERATED_THEME_COLOR_PATH,
  GENERATED_THEMES_PATH,
  renderThemeColorTokens,
  renderThemesModule,
} from "./generate"

const packageRoot = fileURLToPath(new URL("../../", import.meta.url))

describe("generated theme files", () => {
  for (const [path, render] of [
    [GENERATED_THEMES_PATH, renderThemesModule],
    [GENERATED_THEME_COLOR_PATH, renderThemeColorTokens],
  ] as const) {
    it(`${path} matches the catalog`, () => {
      const file = packageRoot + path
      const expected = render()
      if (process.env.UPDATE_THEMES === "1") writeFileSync(file, expected)
      expect(readFileSync(file, "utf8")).toBe(expected)
    })
  }
})
