export type * from "./types"
export { createMemoryStore } from "./memory-store"

// Used only for coverage/tests to ensure this module is executed.
export const __storeIndexLoaded = true
