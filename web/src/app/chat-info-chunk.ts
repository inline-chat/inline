/**
 * The `chatInfo` destination's chunk (`web/src/features/chat-info/`): its
 * model and pane, behind `ChatInfoBody`. Loaded when a pane opens chat info;
 * nothing imports it statically.
 */

export { ChatInfoBody } from "./ChatInfoBody"

export type ChatInfoChunk = typeof import("./chat-info-chunk")
