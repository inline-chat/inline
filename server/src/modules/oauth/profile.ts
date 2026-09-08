import { normalizeUsername } from "@in/server/utils/normalize"

export type OAuthProfile = {
  firstName: string | null
  lastName: string | null
  username: string | null
  pendingSetup: boolean | null
}

export function needsOAuthProfile(user: OAuthProfile): boolean {
  return user.pendingSetup === true || !user.firstName?.trim() || !user.username?.trim()
}

export function parseOAuthProfile(name: string, username: string) {
  const parts = name.trim().split(/\s+/u)
  const firstName = parts.shift() ?? ""
  const lastName = parts.join(" ")
  const handle = normalizeUsername(username)
  if (!firstName || firstName.length > 256 || lastName.length > 256) {
    return { error: "Enter your name (up to 256 characters per name)." } as const
  }
  if (handle.length < 2 || handle.length > 256) {
    return { error: "Choose a username between 2 and 256 characters." } as const
  }
  return { profile: { firstName, lastName, username: handle } } as const
}
