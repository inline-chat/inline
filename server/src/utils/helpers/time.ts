export const delay = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms))
export const debugDelay = (ms: number) => {
  // Avoid importing env.ts here: env.ts can be strict about required vars (e.g. DATABASE_URL),
  // and time helpers should be safe to use in any context (scripts/tests) without env setup.
  if (process.env.NODE_ENV === "development") {
    return new Promise((resolve) => setTimeout(resolve, ms))
  }
  return Promise.resolve()
}
