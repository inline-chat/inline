/**
 * The boot snapshot: what was on screen, saved when the page hides, painted
 * synchronously on the next start before the core exists, then reconciled
 * with the core's first answer. See README.md in this directory.
 */
export {
  BOOT_SNAPSHOT_BUDGET,
  BOOT_SNAPSHOT_FORMAT,
  BOOT_SNAPSHOT_KEY,
  BOOT_SNAPSHOT_VERSION,
  SNAPSHOT_ROWS_ABOVE_PLACE,
  SNAPSHOT_SIDEBAR_ITEMS,
  SNAPSHOT_WINDOW_ROWS,
  parseBootSnapshot,
  type BootSnapshot,
  type SnapshotProblem,
} from "./format"
export { eraseBootSnapshot, readBootSnapshot, writeBootSnapshot, type BootSnapshotRead, type SnapshotStorage } from "./storage"
export { captureBootSnapshot, type Capture, type CaptureOptions } from "./capture"
export { provisionalData } from "./restore"
export { DeferredEndpoint } from "./deferred-endpoint"
export { PENDING_TOKEN, hintedAuthStore } from "./hinted-auth"
export {
  SNAPSHOT_IDLE_INTERVAL_MS,
  attachBootSnapshotSaver,
  type BootSnapshotSaver,
  type SaveReason,
  type SaveResult,
} from "./saver"
