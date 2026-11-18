import type { ListChange, RowKey, SubId } from "@inline/core-protocol"

/** Structural equality for plain row data (objects, arrays, primitives). */
export const plainEqual = (left: unknown, right: unknown): boolean => {
  if (Object.is(left, right)) return true
  if (
    left == null ||
    right == null ||
    typeof left !== "object" ||
    typeof right !== "object"
  ) {
    return false
  }
  if (Array.isArray(left)) {
    if (!Array.isArray(right) || left.length !== right.length) return false
    for (let index = 0; index < left.length; index++) {
      if (!plainEqual(left[index], right[index])) return false
    }
    return true
  }
  if (Array.isArray(right)) return false
  const leftKeys = Object.keys(left)
  const rightKeys = Object.keys(right)
  if (leftKeys.length !== rightKeys.length) return false
  for (const key of leftKeys) {
    if (!Object.prototype.hasOwnProperty.call(right, key)) return false
    if (
      !plainEqual(
        (left as Record<string, unknown>)[key],
        (right as Record<string, unknown>)[key],
      )
    ) {
      return false
    }
  }
  return true
}

/**
 * The smallest single list change that turns `before` into `after`: one
 * splice over the span between their common prefix and suffix, or a replace
 * when that span is most of the list. `null` when equal.
 */
export const diffList = (
  sub: SubId,
  before: readonly RowKey[] | undefined,
  after: readonly RowKey[],
): ListChange | null => {
  if (before == null) return { sub, op: "replace", keys: after.slice() }
  let prefix = 0
  const shorter = Math.min(before.length, after.length)
  while (prefix < shorter && before[prefix] === after[prefix]) prefix++
  if (prefix === before.length && prefix === after.length) return null
  let suffix = 0
  while (
    suffix < shorter - prefix &&
    before[before.length - 1 - suffix] === after[after.length - 1 - suffix]
  ) {
    suffix++
  }
  const remove = before.length - prefix - suffix
  const insert = after.slice(prefix, after.length - suffix)
  if (prefix === 0 && suffix === 0) return { sub, op: "replace", keys: after.slice() }
  return { sub, op: "splice", index: prefix, remove, insert }
}
