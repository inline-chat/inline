/**
 * The autocomplete chunk: the list's keyboard cursor (the kit's listbox)
 * and the popup view. Loaded on the first `@`, `:` or `/` in any composer
 * (`loadAutocompleteChunk` in `autocomplete.ts`); nothing imports it
 * statically, so plain typing, Enter and IME never wait for it.
 */

export { createAutocompleteCursor } from "./autocomplete-cursor"
export { AutocompletePopup } from "./AutocompletePopup"
