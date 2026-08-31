/** Retry only a fully rolled-back PostgreSQL deadlock, never a post-commit
 * projection or an ambiguous transport failure. Group mutations can acquire
 * their final user-bucket set only after inspecting the locked chat. */
export async function retryParticipantMutation<T>(
  transaction: () => Promise<T>,
  wait: (milliseconds: number) => Promise<void> = (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds)),
): Promise<T> {
  for (let attempt = 0; ; attempt += 1) {
    try {
      return await transaction()
    } catch (error) {
      if (attempt >= 2 || !isDeadlock(error)) throw error
      await wait(25 * (attempt + 1) + Math.floor(Math.random() * 25))
    }
  }
}

function isDeadlock(error: unknown): boolean {
  let current = error
  for (let depth = 0; depth < 4 && typeof current === "object" && current !== null; depth += 1) {
    if ("code" in current && current.code === "40P01") return true
    current = "cause" in current ? current.cause : undefined
  }
  return false
}
