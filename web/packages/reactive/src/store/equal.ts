/**
 * Structural equality for plain, structured-cloneable data: rows, resources,
 * key lists. Used to keep the identity of values that did not change, so
 * `===` is a valid "did it change" check for every observer.
 */
export const plainEqual = (a: unknown, b: unknown): boolean => {
  if (Object.is(a, b)) return true
  if (typeof a !== "object" || typeof b !== "object" || a === null || b === null) return false
  if (Array.isArray(a)) {
    if (!Array.isArray(b) || a.length !== b.length) return false
    for (let i = 0; i < a.length; i++) {
      if (!plainEqual(a[i], b[i])) return false
    }
    return true
  }
  if (Array.isArray(b)) return false
  const aRecord = a as Record<string, unknown>
  const bRecord = b as Record<string, unknown>
  let count = 0
  for (const key in aRecord) {
    if (!Object.hasOwn(aRecord, key)) continue
    // An absent key and a key set to undefined are the same row.
    const aValue = aRecord[key]
    if (aValue === undefined) continue
    count += 1
    if (!plainEqual(aValue, bRecord[key])) return false
  }
  for (const key in bRecord) {
    if (Object.hasOwn(bRecord, key) && bRecord[key] !== undefined) count -= 1
  }
  return count === 0
}

/** Same keys in the same order. */
export const sameKeys = <T>(a: readonly T[], b: readonly T[]): boolean => {
  if (a === b) return true
  if (a.length !== b.length) return false
  for (let i = 0; i < a.length; i++) {
    if (a[i] !== b[i]) return false
  }
  return true
}
