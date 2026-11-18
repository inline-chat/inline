/**
 * The settings destination's chunk: the pane's body (`SettingsBody`: its
 * model and `SettingsView` with its pages), loaded after the shell's first
 * paint or when a pane opens `/settings` first.
 */

export { SettingsView } from "../features/settings"
export { SettingsBody } from "./SettingsBody"

export type SettingsChunk = typeof import("./settings-chunk")
