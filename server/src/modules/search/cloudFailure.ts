// Driver and crypto messages may include user content. Export only allowlisted classes.
export function searchFailureClass(error: unknown): "database-timeout" | "database" | "crypto" | "internal" {
  for (const value of [error, error instanceof Error ? error.cause : undefined]) {
    if (!value || typeof value !== "object") continue
    if ("code" in value && typeof value.code === "string") {
      if (["57014", "55P03"].includes(value.code)) return "database-timeout"
      if (/^[0-9A-Z]{5}$/.test(value.code)) return "database"
    }
    if (value instanceof Error && value.name === "CloudSearchCryptoError") return "crypto"
  }
  return "internal"
}
