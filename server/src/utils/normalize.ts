export const normalizeEmail = (email: string): string => {
  return email.trim().toLowerCase()
}

/** Existing public handles are looked up literally; never sanitize a lookup into another identity. */
export const normalizeHandleLookup = (value: string): string => value.trim().replace(/^@+/, "")

export const MAX_USERNAME_LENGTH = 64

/** Sanitize input while preserving casing. Validate separately; never truncate or invent a fallback. */
export const normalizeUsername = (value: string): string => {
  let username = normalizeHandleLookup(value.normalize("NFKD"))
  // A pasted email is a common signup mistake. Do not publish its domain as part of a handle.
  if (/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(username)) {
    username = username.slice(0, username.indexOf("@"))
  }
  return username
    .replace(/\p{M}/gu, "")
    .replace(/[^a-zA-Z0-9_]+/g, "_")
    .replace(/^_+|_+$/g, "")
}

export const isValidUsername = (value: string): boolean =>
  value.length >= 2 && value.length <= MAX_USERNAME_LENGTH && /^[a-zA-Z0-9][a-zA-Z0-9_]*[a-zA-Z0-9]$/.test(value)

export const normalizePhoneNumber = (phoneNumber: string): string => {
  return phoneNumber.trim().replace(/\s+/g, "")
}
