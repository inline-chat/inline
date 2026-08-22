export const locales = [
  { code: "en", pathSegment: "", hrefLang: "en", name: "English" },
  { code: "zh-CN", pathSegment: "zh-cn", hrefLang: "zh-Hans", name: "简体中文" },
  { code: "ja", pathSegment: "ja", hrefLang: "ja", name: "日本語" },
  { code: "zh-TW", pathSegment: "zh-tw", hrefLang: "zh-Hant", name: "繁體中文" },
  { code: "es", pathSegment: "es", hrefLang: "es", name: "Español" },
  { code: "fr", pathSegment: "fr", hrefLang: "fr", name: "Français" },
  { code: "pt", pathSegment: "pt", hrefLang: "pt", name: "Português" },
  { code: "ar", pathSegment: "ar", hrefLang: "ar", name: "العربية" },
  { code: "fa", pathSegment: "fa", hrefLang: "fa", name: "فارسی" },
  { code: "de", pathSegment: "de", hrefLang: "de", name: "Deutsch" },
  { code: "ko", pathSegment: "ko", hrefLang: "ko", name: "한국어" },
  { code: "it", pathSegment: "it", hrefLang: "it", name: "Italiano" },
] as const

export type Locale = (typeof locales)[number]["code"]
export type ThemePreference = "system" | "light" | "dark"

export const localeCookieKey = "inline_landing_locale"
export const themeStorageKey = "inline_landing_theme"

type PreferenceCopy = {
  footer: string
  preferences: string
  language: string
  appearance: string
  system: string
  light: string
  dark: string
}

export const preferenceCopy: Record<Locale, PreferenceCopy> = {
  en: {
    footer: "Footer",
    preferences: "Language and appearance",
    language: "Language",
    appearance: "Appearance",
    system: "System",
    light: "Light",
    dark: "Dark",
  },
  "zh-CN": {
    footer: "页脚",
    preferences: "语言和外观",
    language: "语言",
    appearance: "外观",
    system: "跟随系统",
    light: "浅色",
    dark: "深色",
  },
  ja: {
    footer: "フッター",
    preferences: "言語と外観",
    language: "言語",
    appearance: "外観",
    system: "システム",
    light: "ライト",
    dark: "ダーク",
  },
  "zh-TW": {
    footer: "頁尾",
    preferences: "語言和外觀",
    language: "語言",
    appearance: "外觀",
    system: "跟隨系統",
    light: "淺色",
    dark: "深色",
  },
  es: {
    footer: "Pie de página",
    preferences: "Idioma y apariencia",
    language: "Idioma",
    appearance: "Apariencia",
    system: "Sistema",
    light: "Claro",
    dark: "Oscuro",
  },
  fr: {
    footer: "Pied de page",
    preferences: "Langue et apparence",
    language: "Langue",
    appearance: "Apparence",
    system: "Système",
    light: "Clair",
    dark: "Sombre",
  },
  pt: {
    footer: "Rodapé",
    preferences: "Idioma e aparência",
    language: "Idioma",
    appearance: "Aparência",
    system: "Sistema",
    light: "Claro",
    dark: "Escuro",
  },
  ar: {
    footer: "التذييل",
    preferences: "اللغة والمظهر",
    language: "اللغة",
    appearance: "المظهر",
    system: "النظام",
    light: "فاتح",
    dark: "داكن",
  },
  fa: {
    footer: "پابرگ",
    preferences: "زبان و ظاهر",
    language: "زبان",
    appearance: "ظاهر",
    system: "سیستم",
    light: "روشن",
    dark: "تیره",
  },
  de: {
    footer: "Fußzeile",
    preferences: "Sprache und Darstellung",
    language: "Sprache",
    appearance: "Darstellung",
    system: "System",
    light: "Hell",
    dark: "Dunkel",
  },
  ko: {
    footer: "바닥글",
    preferences: "언어 및 화면 모드",
    language: "언어",
    appearance: "화면 모드",
    system: "시스템",
    light: "라이트",
    dark: "다크",
  },
  it: {
    footer: "Piè di pagina",
    preferences: "Lingua e aspetto",
    language: "Lingua",
    appearance: "Aspetto",
    system: "Sistema",
    light: "Chiaro",
    dark: "Scuro",
  },
}

const supportedLocales = new Set<string>(locales.map(({ code }) => code))

export function isLocale(value: unknown): value is Locale {
  return typeof value === "string" && supportedLocales.has(value)
}

export function landingPathForLocale(locale: Locale): string {
  const pathSegment = locales.find(({ code }) => code === locale)?.pathSegment
  return pathSegment ? `/beta/${pathSegment}` : "/beta"
}

export function localeFromPathSegment(pathSegment: string): Locale | null {
  const normalized = pathSegment.toLowerCase()
  return locales.find((locale) => locale.pathSegment === normalized && locale.pathSegment !== "")?.code ?? null
}

export function localeForLandingPath(pathname: string): Locale | null {
  if (pathname === "/beta" || pathname === "/beta/") return "en"

  const match = pathname.match(/^\/beta\/([^/]+)\/?$/)
  return match ? localeFromPathSegment(match[1]) : null
}

export function directionForLocale(locale: Locale): "ltr" | "rtl" {
  return locale === "ar" || locale === "fa" ? "rtl" : "ltr"
}

export function resolveTheme(storedTheme: string | null): ThemePreference {
  return storedTheme === "light" || storedTheme === "dark" ? storedTheme : "system"
}
