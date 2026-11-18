/**
 * Quick Search's chunk: the palette and its wiring, loaded after the shell's
 * first paint (or on the first Mod+K). Nothing of it is needed to paint the
 * window: the command is registered by the session, and the palette is a
 * closed `<dialog>` until opened.
 */

export { QuickSearchPalette, wireQuickSearch } from "../features/quick-search"
/**
 * Message search over the core's local index (`searchMessages`), and server
 * people (`searchUsers`). Server message search covers one chat only, so
 * messages in Quick Search stay local (find in chat merges the server's).
 */
export { createCoreMessageSource, createCoreRemoteSource } from "../features/quick-search/core-sources"
export { wireSessionQuickSearch } from "./quick-search-session"

export type QuickSearchChunk = typeof import("./quick-search-chunk")
