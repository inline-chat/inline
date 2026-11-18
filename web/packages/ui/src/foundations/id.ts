/**
 * IDs for ARIA wiring (aria-controls, aria-labelledby, aria-activedescendant).
 * Unique per document, stable for a controller's lifetime, and distinct from
 * React's useId format so the two never collide.
 */

let counter = 0

export const createId = (prefix = "ui"): string => `in-${prefix}-${(++counter).toString(36)}`

/** Derive a child ID, e.g. an option's ID from its listbox's ID and its key. */
export const childId = (parent: string, key: string): string =>
  `${parent}-${key.replace(/[^A-Za-z0-9_-]/g, (char) => `_${char.charCodeAt(0).toString(36)}`)}`
