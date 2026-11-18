export type InlineSqliteUnavailableReason =
  | "worker-required"
  | "opfs-unsupported"
  | "opfs-permission-denied"
  | "wasm-initialization-failed"
  | "opfs-initialization-failed"
  /**
   * Another context still holds this account's storage. The files are intact.
   * Retrying later can succeed; falling back to memory would hide real data.
   */
  | "opfs-busy"

export class InlineSqliteUnavailableError extends Error {
  constructor(
    readonly reason: InlineSqliteUnavailableReason,
    options?: ErrorOptions,
  ) {
    super(`Inline SQLite persistence unavailable: ${reason}`, options)
    this.name = "InlineSqliteUnavailableError"
  }
}

/**
 * True when running without persistence is an honest fallback: the browser
 * cannot keep a replica at all. Never true for a busy or failed pool, where a
 * replica may exist and must not be shadowed by an empty in-memory one.
 */
export const isInlineSqliteStartupFallbackSafe = (
  error: unknown,
): error is InlineSqliteUnavailableError =>
  error instanceof InlineSqliteUnavailableError &&
  (error.reason === "worker-required" ||
    error.reason === "opfs-unsupported" ||
    error.reason === "opfs-permission-denied")
