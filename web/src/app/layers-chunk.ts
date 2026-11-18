/**
 * The shell's message action layers, neither of which is on the first
 * frame: the reaction picker and the confirmation alert (the kit's popover
 * and dialog controllers and their views, driven by `MessageActions`).
 * Warmed on the idle lane right after the first paint (`afterFirstPaint` in
 * `view-chunks.ts`); the first question or picker loads it at once if it
 * comes first (`MessageActions`). The toast region stays in the shell: the
 * kit's `Controls` module that holds it is in the initial set for the split
 * view anyway, so moving it saved nothing (measured).
 */

export { kitLayers } from "../features/chat/message-layers"
export { MessageActionLayers } from "../features/chat/MessageActionLayers"

export type LayersChunk = typeof import("./layers-chunk")
