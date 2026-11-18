/**
 * The HTML paste module (`./paste`), loaded on first use. The controller
 * pastes plain text and the composer's own payloads without it
 * (`quickPaste`); an HTML paste that arrives before it is read from the
 * clipboard inside the paste event and parsed when the module is here.
 *
 * The app warms it after its first paint with the same specifier
 * (`import("@inline/composer/paste")`), so both resolve to one chunk.
 */

export type PasteModule = typeof import("./paste")

let loaded: PasteModule | null = null
let loading: Promise<PasteModule> | null = null

/** Load the HTML paste module (once). */
export const loadPasteModule = (): Promise<PasteModule> => {
  if (loaded) return Promise.resolve(loaded)
  loading ??= import("./paste").then(
    (module) => {
      loaded = module
      return module
    },
    (error: unknown) => {
      // A failed load (network) is tried again on the next paste.
      loading = null
      throw error
    },
  )
  return loading
}

/** The module if it has loaded, else `null`. */
export const pasteModuleIfLoaded = (): PasteModule | null => loaded
