/**
 * The autocomplete list for the composer's active trigger (`@`, `:`, `/`).
 *
 * Framework-free and DOM-free. The rows come from the caller's `suggest`
 * function (here, in the first-frame path: it is a computed and nothing
 * more). The keyboard cursor (the UI kit's `ListboxController`) and the
 * popup view are the autocomplete chunk (`autocomplete-chunk.ts`), loaded
 * when the first trigger appears; until it is here the list is closed and
 * every key keeps its plain meaning, so typing, Enter and IME never wait for
 * it. Accepting goes back to the composer controller, then to the row's own
 * `onAccept` (the emoji source counts the pick there). Focus never leaves
 * the editor: the composer's binding routes arrows, Enter, Tab and Escape
 * here while a trigger is active, and never during a composition.
 */

import type { AutocompleteItem, AutocompleteKey, Trigger, TriggerKind } from "@inline/composer"
import { computed, effect, signal, untracked, type Dispose, type ReadSignal } from "@inline/reactive"
import type { ListboxController } from "@inline/ui"

export type ComposerSuggestion = {
  /** Unique within one list. */
  id: string
  /** The name shown, and what screen readers announce. */
  title: string
  /** A second line or trailing detail: a username, a command's description. */
  subtitle?: string
  /** A person or group: the kit's `Avatar` (initials on the Mac palette, or `src`). */
  avatar?: { name: string; seed?: string; src?: string }
  /** A leading character, for emoji. */
  glyph?: string
  /** What accepting the row inserts. */
  item: AutocompleteItem
  /**
   * Called once after the row was accepted and inserted (Enter, Tab or a
   * click); never for a list that was dismissed or a row that was not
   * inserted. The emoji source records the pick for recents here.
   */
  onAccept?: () => void
}

/**
 * Suggestions for a trigger. Called inside a computed: it may read signals
 * (a member list, search results that arrive later) and the list updates
 * when they change. Return the rows in order; an empty list hides the popup.
 */
export type SuggestFn = (trigger: Trigger) => readonly ComposerSuggestion[]

/** The keyboard cursor over the rows, from the autocomplete chunk. */
export type AutocompleteCursor = {
  readonly listbox: ListboxController
  /** The active option's DOM id while the list is open, for the editor's `aria-activedescendant`. */
  readonly activeDescendant: ReadSignal<string | null>
  handleKey(key: AutocompleteKey): boolean
  dispose(): void
}

/** The autocomplete chunk (cursor and popup view). */
export type AutocompleteChunk = typeof import("./autocomplete-chunk")
/** What the list needs of the chunk: the cursor. The view also uses `AutocompletePopup`. */
export type AutocompleteChunkPart = Pick<AutocompleteChunk, "createAutocompleteCursor"> & Partial<AutocompleteChunk>

let loadedChunk: AutocompleteChunk | null = null
let loadingChunk: Promise<AutocompleteChunk> | null = null

/**
 * Load the autocomplete chunk (once per page). Register this with the app's
 * chunk table as `import("../features/composer/autocomplete-chunk")`; the
 * same specifier resolves to the same chunk.
 */
export const loadAutocompleteChunk = (): Promise<AutocompleteChunk> => {
  if (loadedChunk) return Promise.resolve(loadedChunk)
  loadingChunk ??= import("./autocomplete-chunk").then(
    (chunk) => {
      loadedChunk = chunk
      return chunk
    },
    (error: unknown) => {
      loadingChunk = null
      throw error
    },
  )
  return loadingChunk
}

export type ComposerAutocompleteOptions = {
  /** The composer controller's active trigger. */
  trigger: ReadSignal<Trigger | null>
  /** Whether the editor has focus. The popup hides while it does not. */
  focused: ReadSignal<boolean>
  suggest?: SuggestFn
  /** The composer controller's `acceptAutocomplete`. */
  accept: (item: AutocompleteItem) => boolean
  label?: string
  /**
   * The chunk, already loaded (tests, the lab), or how to load it. Default
   * `loadAutocompleteChunk` on the first trigger (in a page; not in Node);
   * once loaded in the page, later lists have it from their first frame.
   */
  chunk?: AutocompleteChunkPart | (() => Promise<AutocompleteChunkPart>)
}

export type ComposerAutocomplete = ReturnType<typeof createComposerAutocomplete>

const none: readonly ComposerSuggestion[] = Object.freeze([])

const sameSuggestions = (a: readonly ComposerSuggestion[], b: readonly ComposerSuggestion[]) =>
  a === b || (a.length === b.length && a.every((s, i) => s === b[i]))

export const createComposerAutocomplete = (options: ComposerAutocompleteOptions) => {
  const suggestions = computed<readonly ComposerSuggestion[]>(
    () => {
      const trigger = options.trigger.get()
      if (!trigger || !options.suggest) return none
      try {
        return options.suggest(trigger)
      } catch {
        // A failing source shows no list rather than breaking the composer.
        return none
      }
    },
    { equals: sameSuggestions },
  )

  const kind = computed<TriggerKind | null>(() => options.trigger.get()?.kind ?? null)

  const given = typeof options.chunk === "function" ? undefined : options.chunk
  const chunk = signal<AutocompleteChunkPart | null>(given ?? (options.chunk ? null : loadedChunk))
  const cursor = signal<AutocompleteCursor | null>(null)
  let disposed = false

  const isOpen = computed(
    () =>
      cursor.get() !== null && options.focused.get() && options.trigger.get() !== null && suggestions.get().length > 0,
  )

  const accept = (id: string): boolean => {
    const suggestion = suggestions.peek().find((s) => s.id === id)
    if (!suggestion) return false
    if (!options.accept(suggestion.item)) return false
    try {
      suggestion.onAccept?.()
    } catch {
      // A failing hook never undoes the insertion.
    }
    return true
  }

  const install = (part: AutocompleteChunkPart) => {
    if (disposed || cursor.peek()) return
    chunk.set(part)
    cursor.set(part.createAutocompleteCursor({ suggestions, trigger: options.trigger, isOpen, accept, ...(options.label ? { label: options.label } : {}) }))
  }

  let loading = false
  const startLoading = () => {
    // Without a document (Node: tests of the pane) there is no popup to show: the list stays closed.
    const load =
      typeof options.chunk === "function" ? options.chunk : options.chunk || typeof document === "undefined" ? null : loadAutocompleteChunk
    if (!load) return
    void load().then(install, () => {
      // Not loaded (offline): the list stays closed; the next trigger tries again.
      loading = false
    })
  }

  // The cursor is made on the first trigger (the chunk loads then, unless it is here already).
  const stopLoad: Dispose = effect(() => {
    const active = options.trigger.get() !== null
    untracked(() => {
      if (!active || cursor.peek() || disposed) return
      const ready = chunk.peek()
      if (ready) install(ready)
      else if (!loading) {
        loading = true
        startLoading()
      }
    })
  })

  // Keep the rows live from the first trigger, as the list did when it was always made: a source
  // that loads on its first call (mentions, emoji) starts then, not when the popup's chunk arrives.
  const stopRows: Dispose = effect(() => void suggestions.get())

  const activeDescendant = computed<string | null>(() => cursor.get()?.activeDescendant.get() ?? null)

  /**
   * A key routed from the composer while a trigger is active. Returns true when
   * the list used it. Escape is left to the controller, which dismisses the
   * trigger; with no rows on screen every key keeps its plain meaning.
   */
  const handleKey = (key: AutocompleteKey): boolean => cursor.peek()?.handleKey(key) ?? false

  return {
    suggestions: suggestions as ReadSignal<readonly ComposerSuggestion[]>,
    kind: kind as ReadSignal<TriggerKind | null>,
    isOpen: isOpen as ReadSignal<boolean>,
    activeDescendant: activeDescendant as ReadSignal<string | null>,
    /** The keyboard cursor, once the chunk is here. */
    cursor: cursor as ReadSignal<AutocompleteCursor | null>,
    /** The chunk (cursor and popup view), once here. */
    chunk: chunk as ReadSignal<AutocompleteChunkPart | null>,
    handleKey,
    accept,
    dispose: () => {
      disposed = true
      stopLoad()
      stopRows()
      cursor.peek()?.dispose()
    },
  }
}
