"use client"

import * as stylex from "@stylexjs/stylex"
import { useEffect, useState } from "react"
import { LandingPreferences } from "./LandingPreferences"
import {
  directionForLocale,
  preferenceCopy,
  resolveTheme,
  themeStorageKey,
  type Locale,
  type ThemePreference,
} from "./preferences"
import { darkTheme, landingColors, lightTheme } from "./tokens.stylex"

export function PublicBetaLanding({
  locale,
  onLocaleChange,
}: {
  locale: Locale
  onLocaleChange: (locale: Locale) => void
}) {
  const [theme, setTheme] = useState<ThemePreference>("system")
  const direction = directionForLocale(locale)
  const copy = preferenceCopy[locale]

  useEffect(() => {
    setTheme(resolveTheme(readPreference(themeStorageKey)))
  }, [])

  useEffect(() => {
    document.documentElement.lang = locale
    document.documentElement.dir = direction
    document.documentElement.style.colorScheme = theme === "system" ? "light dark" : theme
  }, [direction, locale, theme])

  useEffect(() => {
    return () => {
      document.documentElement.lang = "en"
      document.documentElement.dir = "ltr"
      document.documentElement.style.removeProperty("color-scheme")
    }
  }, [])

  const changeTheme = (nextTheme: ThemePreference) => {
    setTheme(nextTheme)
    writePreference(themeStorageKey, nextTheme)
  }

  return (
    <div
      lang={locale}
      dir={direction}
      {...stylex.props(
        styles.page,
        locale === "fa" && styles.persianFont,
        theme === "light" && lightTheme,
        theme === "dark" && darkTheme,
        theme === "light" && styles.lightColorScheme,
        theme === "dark" && styles.darkColorScheme,
      )}
    >
      <main {...stylex.props(styles.main)} />
      <footer aria-label={copy.footer} {...stylex.props(styles.footer)} />

      <LandingPreferences
        locale={locale}
        theme={theme}
        copy={copy}
        onLocaleChange={onLocaleChange}
        onThemeChange={changeTheme}
      />
    </div>
  )
}

function readPreference(key: string): string | null {
  try {
    return window.localStorage.getItem(key)
  } catch {
    return null
  }
}

function writePreference(key: string, value: string) {
  try {
    window.localStorage.setItem(key, value)
  } catch {
    // The preference remains active for this page when storage is unavailable.
  }
}

const styles = stylex.create({
  page: {
    minHeight: "100vh",
    display: "flex",
    flexDirection: "column",
    backgroundColor: landingColors.canvas,
    color: landingColors.text,
    colorScheme: { default: "light", "@media (prefers-color-scheme: dark)": "dark" },
    fontFamily: "ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif",
  },
  persianFont: {
    fontFamily:
      "Vazirmatn, ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif",
  },
  lightColorScheme: {
    colorScheme: "light",
  },
  darkColorScheme: {
    colorScheme: "dark",
  },
  main: {
    flexGrow: 1,
    minHeight: "60vh",
  },
  footer: {
    width: "100%",
  },
})
