/** A `name` anywhere in an error's cause chain. */
export const hasErrorNamed = (error: unknown, name: string, depth = 0): boolean => {
  if (error == null || typeof error !== "object" || depth > 8) return false
  if ((error as { name?: unknown }).name === name) return true
  if (error instanceof AggregateError && error.errors.some((inner) => hasErrorNamed(inner, name, depth + 1))) {
    return true
  }
  return hasErrorNamed((error as { cause?: unknown }).cause, name, depth + 1)
}
