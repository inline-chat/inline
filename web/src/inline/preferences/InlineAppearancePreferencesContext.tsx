import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useRef,
  useSyncExternalStore,
  type ReactNode,
} from "react"
import {
  defaultInlineAppearancePreferences,
  InlineAppearancePreferencesStore,
  type InlineAppearancePreferences,
} from "./InlineAppearancePreferences"

type InlineAppearancePreferencesValue = {
  preferences: InlineAppearancePreferences
  update: (
    patch: Partial<InlineAppearancePreferences>,
  ) => void
  subscribeBeforeChange: InlineAppearancePreferencesStore["subscribeBeforeChange"]
}

const InlineAppearancePreferencesContext =
  createContext<InlineAppearancePreferencesValue | undefined>(undefined)

export function InlineAppearancePreferencesProvider({
  children,
}: {
  children: ReactNode
}) {
  const store = useRef<InlineAppearancePreferencesStore>(undefined)
  if (!store.current) {
    store.current = new InlineAppearancePreferencesStore(
      typeof window === "undefined" ? undefined : window.localStorage,
      typeof window === "undefined" ? undefined : window,
    )
  }
  const preferences = useSyncExternalStore(
    store.current.subscribe,
    store.current.getSnapshot,
    () => defaultInlineAppearancePreferences,
  )
  useEffect(() => () => store.current?.destroy(), [])
  const update = useCallback(
    (patch: Partial<InlineAppearancePreferences>) => {
      store.current?.update(patch)
    },
    [],
  )
  const value = useMemo<InlineAppearancePreferencesValue>(
    () => ({
      preferences,
      update,
      subscribeBeforeChange: store.current!.subscribeBeforeChange,
    }),
    [preferences, update],
  )

  return (
    <InlineAppearancePreferencesContext.Provider
      value={value}
    >
      {children}
    </InlineAppearancePreferencesContext.Provider>
  )
}

export const useInlineAppearancePreferences = () => {
  const value = useContext(InlineAppearancePreferencesContext)
  if (!value) {
    throw new Error(
      "Inline appearance preferences require InlineAppearancePreferencesProvider",
    )
  }
  return value
}
