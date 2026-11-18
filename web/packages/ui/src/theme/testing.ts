/** Fakes for theme tests: a recording root element, a scriptable matchMedia, a binding with readable class names. */

import type { AppearanceBinding, AppearanceRootElement, MatchMedia } from "./controller"

export type FakeRoot = AppearanceRootElement & {
  readonly classes: Set<string>
  readonly attributes: Map<string, string>
  readonly properties: Map<string, string>
  /** Every mutation, in order: "+class", "-class", "@attr=value", "@-attr", "--prop=value", "--prop=". */
  readonly log: string[]
}

export function fakeRoot(): FakeRoot {
  const classes = new Set<string>()
  const attributes = new Map<string, string>()
  const properties = new Map<string, string>()
  const log: string[] = []
  return {
    classes,
    attributes,
    properties,
    log,
    classList: {
      add: (...tokens) => {
        for (const t of tokens) {
          if (!classes.has(t)) log.push(`+${t}`)
          classes.add(t)
        }
      },
      remove: (...tokens) => {
        for (const t of tokens) {
          if (classes.delete(t)) log.push(`-${t}`)
        }
      },
    },
    setAttribute: (name, value) => {
      if (attributes.get(name) !== value) log.push(`@${name}=${value}`)
      attributes.set(name, value)
    },
    removeAttribute: (name) => {
      if (attributes.delete(name)) log.push(`@-${name}`)
    },
    hasAttribute: (name) => attributes.has(name),
    style: {
      setProperty: (name, value) => {
        if (properties.get(name) !== value) log.push(`${name}=${value}`)
        properties.set(name, value)
      },
      removeProperty: (name) => {
        const previous = properties.get(name) ?? ""
        if (properties.delete(name)) log.push(`${name}=`)
        return previous
      },
    },
  }
}

export type FakeMatchMedia = MatchMedia & {
  /** Change the system appearance and notify listeners. */
  setDark(dark: boolean): void
  listenerCount(): number
}

export function fakeMatchMedia(initialDark = false): FakeMatchMedia {
  let dark = initialDark
  const listeners = new Set<() => void>()
  const matchMedia = ((query: string) => {
    if (query !== "(prefers-color-scheme: dark)") throw new Error(`Unexpected query ${query}`)
    return {
      get matches() {
        return dark
      },
      addEventListener: (_type: "change", listener: () => void) => {
        listeners.add(listener)
      },
      removeEventListener: (_type: "change", listener: () => void) => {
        listeners.delete(listener)
      },
    }
  }) as unknown as FakeMatchMedia
  matchMedia.setDark = (value) => {
    dark = value
    for (const listener of Array.from(listeners)) listener()
  }
  matchMedia.listenerCount = () => listeners.size
  return matchMedia
}

/** A binding whose class names say what they are: `theme-pink`, `scheme-dark`, two classes for each theme. */
export const fakeBinding: AppearanceBinding = {
  root: "root-canvas",
  appearance: { light: "scheme-light", dark: "scheme-dark", system: "scheme-system" },
  theme: {
    system: "theme-system group-color group-theme-color",
    pink: "theme-pink group-color group-theme-color",
    sunset: "theme-sunset group-color group-theme-color",
    midnight: "theme-midnight group-color group-theme-color",
    ash: "theme-ash group-color group-theme-color",
    flexoki: "theme-flexoki group-color group-theme-color",
    pastel: "theme-pastel group-color group-theme-color",
    "neon-noir": "theme-neon-noir group-color group-theme-color",
  },
  sidebarItemSize: { compact: "", standard: "density-standard" },
  messageFont: { system: "", monospace: "font-mono" },
  vars: {
    messageFontSize: "--message-font-size",
    messageLineHeight: "--message-line-height",
    emojiLarge: "--emoji-large",
    emojiMedium: "--emoji-medium",
    emojiSmall: "--emoji-small",
  },
}
