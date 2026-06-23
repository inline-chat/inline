import { normalizeUsername } from "@in/server/utils/normalize"

export const VERIFIED_USERNAMES = {
  chatgpt: true,
} as const satisfies Readonly<Record<string, true>>

export function isVerifiedUsername(username: string | null | undefined): boolean {
  if (!username) {
    return false
  }

  const normalized = normalizeUsername(username).toLowerCase()
  return VERIFIED_USERNAMES[normalized as keyof typeof VERIFIED_USERNAMES] === true
}
