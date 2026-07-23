export const inlineAppearanceStorageKey =
  "inline-web-appearance-v1"

export type InlineAppearance = "system" | "light" | "dark"
export type InlineMessageStyle = "bubble" | "minimal"
export type InlineSidebarItemSize = "large" | "compact"

export type InlineAppearancePreferences = Readonly<{
  appearance: InlineAppearance
  messageStyle: InlineMessageStyle
  sidebarItemSize: InlineSidebarItemSize
}>

export const defaultInlineAppearancePreferences: InlineAppearancePreferences = {
  appearance: "system",
  messageStyle: "bubble",
  sidebarItemSize: "large",
}

export type InlinePreferenceStorage = Pick<
  Storage,
  "getItem" | "setItem"
>

const isOneOf = <T extends string>(
  value: unknown,
  values: readonly T[],
): value is T =>
  typeof value === "string" && values.includes(value as T)

export const parseInlineAppearancePreferences = (
  value: string | null,
): InlineAppearancePreferences => {
  if (!value) return defaultInlineAppearancePreferences
  try {
    const decoded = JSON.parse(value) as Record<string, unknown>
    return {
      appearance: isOneOf(decoded.appearance, ["system", "light", "dark"])
        ? decoded.appearance
        : defaultInlineAppearancePreferences.appearance,
      messageStyle: isOneOf(decoded.messageStyle, ["bubble", "minimal"])
        ? decoded.messageStyle
        : defaultInlineAppearancePreferences.messageStyle,
      sidebarItemSize: isOneOf(decoded.sidebarItemSize, ["large", "compact"])
        ? decoded.sidebarItemSize
        : defaultInlineAppearancePreferences.sidebarItemSize,
    }
  } catch {
    return defaultInlineAppearancePreferences
  }
}

export const applyInlineAppearancePreferences = (
  preferences: InlineAppearancePreferences,
  root: HTMLElement | undefined =
    typeof document === "undefined" ? undefined : document.documentElement,
) => {
  if (!root) return
  root.dataset.inlineAppearance = preferences.appearance
  root.dataset.inlineMessageStyle = preferences.messageStyle
  root.dataset.inlineSidebarItemSize = preferences.sidebarItemSize
}

type Listener = () => void
type BeforeChangeListener = (
  next: InlineAppearancePreferences,
  current: InlineAppearancePreferences,
) => void

export class InlineAppearancePreferencesStore {
  private snapshot: InlineAppearancePreferences
  private readonly listeners = new Set<Listener>()
  private readonly beforeChangeListeners = new Set<BeforeChangeListener>()
  private readonly onStorage = (event: StorageEvent) => {
    if (event.key !== inlineAppearanceStorageKey) return
    this.replace(parseInlineAppearancePreferences(event.newValue))
  }

  constructor(
    private readonly storage?: InlinePreferenceStorage,
    private readonly eventTarget?: Pick<Window, "addEventListener" | "removeEventListener">,
  ) {
    this.snapshot = parseInlineAppearancePreferences(
      storage?.getItem(inlineAppearanceStorageKey) ?? null,
    )
    applyInlineAppearancePreferences(this.snapshot)
    eventTarget?.addEventListener("storage", this.onStorage)
  }

  getSnapshot = () => this.snapshot

  subscribe = (listener: Listener) => {
    this.listeners.add(listener)
    return () => {
      this.listeners.delete(listener)
    }
  }

  subscribeBeforeChange = (listener: BeforeChangeListener) => {
    this.beforeChangeListeners.add(listener)
    return () => {
      this.beforeChangeListeners.delete(listener)
    }
  }

  update(patch: Partial<InlineAppearancePreferences>) {
    const next = { ...this.snapshot, ...patch }
    this.storage?.setItem(
      inlineAppearanceStorageKey,
      JSON.stringify(next),
    )
    this.replace(next)
  }

  destroy() {
    this.eventTarget?.removeEventListener("storage", this.onStorage)
    this.listeners.clear()
    this.beforeChangeListeners.clear()
  }

  private replace(next: InlineAppearancePreferences) {
    if (
      next.appearance === this.snapshot.appearance &&
      next.messageStyle === this.snapshot.messageStyle &&
      next.sidebarItemSize === this.snapshot.sidebarItemSize
    ) {
      return
    }
    for (const listener of this.beforeChangeListeners) {
      listener(next, this.snapshot)
    }
    this.snapshot = next
    applyInlineAppearancePreferences(next)
    for (const listener of this.listeners) listener()
  }
}

export const inlineAppearanceBootstrapScript = `(()=>{try{const d={appearance:"system",messageStyle:"bubble",sidebarItemSize:"large"};const v=JSON.parse(localStorage.getItem("${inlineAppearanceStorageKey}")||"null")||{};const a=["system","light","dark"].includes(v.appearance)?v.appearance:d.appearance;const m=["bubble","minimal"].includes(v.messageStyle)?v.messageStyle:d.messageStyle;const s=["large","compact"].includes(v.sidebarItemSize)?v.sidebarItemSize:d.sidebarItemSize;const r=document.documentElement;r.dataset.inlineAppearance=a;r.dataset.inlineMessageStyle=m;r.dataset.inlineSidebarItemSize=s}catch{}})()`
