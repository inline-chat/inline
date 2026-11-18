/**
 * The autocomplete list's keyboard cursor: the UI kit's `ListboxController`
 * in its passive form (focus stays in the editor, which points at the active
 * row with `aria-activedescendant`). Part of the autocomplete chunk
 * (`autocomplete-chunk.ts`), loaded on the first `@`, `:` or `/`: plain
 * typing never needs it.
 */

import type { AutocompleteKey, Trigger } from "@inline/composer"
import { computed, effect, untracked, type Dispose, type ReadSignal } from "@inline/reactive"
import { ListboxController, type ListboxOption } from "@inline/ui"
import type { AutocompleteCursor, ComposerSuggestion } from "./autocomplete"

export type AutocompleteCursorOptions = {
  readonly suggestions: ReadSignal<readonly ComposerSuggestion[]>
  readonly trigger: ReadSignal<Trigger | null>
  readonly isOpen: ReadSignal<boolean>
  /** Accept a row by id (the list's own accept, which runs the row's `onAccept`). */
  readonly accept: (id: string) => boolean
  readonly label?: string
}

const triggerKey = (trigger: Trigger | null) => (trigger ? `${trigger.kind}:${trigger.range.from}:${trigger.query}` : null)

export const createAutocompleteCursor = (options: AutocompleteCursorOptions): AutocompleteCursor => {
  const listOptions = computed<readonly ListboxOption[]>(() =>
    options.suggestions.get().map((s) => ({ id: s.id, label: s.title, textValue: s.title })),
  )

  const listbox = new ListboxController({
    items: () => listOptions.get(),
    selectionMode: "none",
    selectionFollowsFocus: false,
    activateOnHover: true,
    clickRunsAction: true,
    label: options.label ?? "Suggestions",
    onAction: (id) => {
      options.accept(id)
    },
  })

  const activeDescendant = computed<string | null>(() => {
    if (!options.isOpen.get()) return null
    const active = listbox.activeId.get()
    return active === null ? null : listbox.optionDomId(active)
  })

  // A new query puts the cursor on the first row; new rows for the same query keep it.
  let lastKey: string | null = null
  const stop: Dispose = effect(() => {
    options.suggestions.get()
    const key = triggerKey(options.trigger.get())
    untracked(() => {
      if (key === null) listbox.setActive(null)
      else listbox.syncActive(key === lastKey ? "keep" : "first")
      lastKey = key
    })
  })

  const handleKey = (key: AutocompleteKey): boolean => {
    if (!options.isOpen.peek()) return false
    switch (key) {
      case "next":
        return listbox.handleKeyDown({ key: "ArrowDown" }, { typeahead: false })
      case "previous":
        return listbox.handleKeyDown({ key: "ArrowUp" }, { typeahead: false })
      case "accept": {
        const active = listbox.activeId.peek()
        return active === null ? false : options.accept(active)
      }
      case "dismiss":
        return false
    }
  }

  return { listbox, activeDescendant, handleKey, dispose: stop }
}
