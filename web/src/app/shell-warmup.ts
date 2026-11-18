/**
 * What the signed-in shell loads after its first paint, and through what.
 * `content` right after the paint (a frame and a task: the rows on screen
 * wait for it); the rest of `afterFirstPaint` (`view-chunks.ts`) that
 * `boot.ts` does not queue itself, on the idle lane in that order; then the
 * emoji table, last.
 *
 * Each name is warmed through the loader the code that waits on it uses,
 * so the warm-up fills the holder the first use reads rather than only the
 * module cache: the menu kit's shared `menuKit` (every lazy context menu
 * opens from it), the composer's `loadAutocompleteChunk` (later composers
 * then have the popup from their first frame), the message layers and Quick
 * Search through the shell's own loaders, emoji through the session's
 * `SessionEmoji`. The composer's paste module has no exported holder; its
 * module is imported (the controller's `loadPasteModule` then resolves a
 * microtask later, which a paste tolerates: it is read inside the paste
 * event and parsed when the module is there).
 *
 * The emoji table (44.5 kB) is warmed last: it is parse cost, not
 * first-frame cost, the service worker precaches it (a local fetch after
 * the first visit), and with it the first picker opens with its data and
 * reaction chips get their names ("thumbs up, 3"). The drawability scan
 * still waits for the first real use.
 *
 * Framework-free; `Shell.tsx` calls `queueShellWarmup` from its paint ref.
 */

import { loadMenuKit } from "@inline/ui"
import { loadAutocompleteChunk } from "../features/composer/autocomplete"
import { afterFirstPaint, bootWarmed, chunkImporters } from "./view-chunks"

type AfterPaintName = (typeof afterFirstPaint)[number]

/** The after-paint chunks the shell warms (everything but `content` and what boot queues). */
export type ShellWarmName = Exclude<AfterPaintName, "content" | (typeof bootWarmed)[number]>

const bootNames: ReadonlySet<string> = new Set(bootWarmed)

/** The shell's warm-up order: `afterFirstPaint`'s, without `content` and boot's names. */
export const shellWarmOrder: readonly ShellWarmName[] = afterFirstPaint.filter(
  (name): name is ShellWarmName => name !== "content" && !bootNames.has(name),
)

/** How each name is warmed, plus the emoji table (not a chunk of the table: the services' own `import()`). */
export type ShellWarmers = { readonly [K in ShellWarmName]: () => unknown } & {
  readonly content: () => unknown
  readonly emojiData: () => unknown
}

export type ShellWarmupLane = { add(task: () => void | Promise<unknown>): void; painted(): void }

/** Queue the shell's loads: `content` after the paint, the rest on the idle lane, the emoji table last; then mark the paint. */
export const queueShellWarmup = (input: {
  readonly afterPaint: (fn: () => void) => void
  readonly warmup: ShellWarmupLane
  readonly warmers: ShellWarmers
}): void => {
  const { warmers, warmup } = input
  input.afterPaint(() => void warmers.content())
  for (const name of shellWarmOrder) warmup.add(async () => void (await warmers[name]()))
  warmup.add(async () => void (await warmers.emojiData()))
  warmup.painted()
}

export type ShellWarmSources = {
  readonly content: () => unknown
  readonly layers: () => unknown
  readonly quickSearch: () => unknown
  readonly settings: () => unknown
  readonly emoji?: {
    loadServices(): Promise<unknown>
    loadPickers(): Promise<unknown>
    warmData(): Promise<unknown>
  }
}

/** The warmers for a shell: the shell's own loaders, and the feature holders named above. */
export const shellWarmers = (sources: ShellWarmSources): ShellWarmers => ({
  content: sources.content,
  layers: sources.layers,
  menus: () => loadMenuKit(),
  composerAutocomplete: () => loadAutocompleteChunk(),
  composerPaste: () => chunkImporters.composerPaste(),
  emoji: () => sources.emoji?.loadServices(),
  emojiPickers: () => sources.emoji?.loadPickers(),
  quickSearch: sources.quickSearch,
  settings: sources.settings,
  emojiData: () => sources.emoji?.warmData(),
})
