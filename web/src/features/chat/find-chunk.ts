/**
 * Find in chat's chunk (`web/src/features/find/`): the model, its source
 * over the core's `findInChat` and `countMessages`, and the bar. Loaded on
 * the first Mod+F (`ChatFind.open`); nothing imports it statically. The
 * commands (`find/commands.ts`) and the selection reader are small and stay
 * in the shell, so Mod+F is bound from the first frame.
 */

export { FindBar } from "../find/FindBar"
export { FindInChatModel } from "../find/find-model"
/** The device's index, and the server's search in the chat (`searchServerMessages`), merged by message ID in the model. */
export { coreFindSource, coreServerFindSource } from "../find/find-source"

export type FindChunk = typeof import("./find-chunk")
