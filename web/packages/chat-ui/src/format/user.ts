/**
 * Names and initials for a user row, by the Apple clients' rules
 * (`InlineKit/Models/User.swift` `displayName`, `InlineAvatarCore/
 * InlineAvatarPresentation.swift`).
 *
 * The web `UserRow` has no email or phone number yet, so those fallbacks of
 * the Mac rules are skipped.
 */

import type { UserRow } from "@inline/core-protocol"
import { firstGrapheme } from "../text/graphemes"

export type UserNameFields = Pick<UserRow, "firstName" | "lastName" | "username">

const normalized = (value: unknown): string | undefined => {
  if (typeof value !== "string") return undefined
  const trimmed = value.trim()
  return trimmed.length > 0 ? trimmed : undefined
}

const normalizedUsername = (value: unknown): string | undefined => {
  const name = normalized(value)?.replace(/^@+|@+$/g, "")
  return name && name.length > 0 ? name : undefined
}

/** "Ada Lovelace", else the first or last name alone, else the username, else "User". */
export const userDisplayName = (user: UserNameFields | undefined): string => {
  if (!user) return "User"
  const full = [normalized(user.firstName), normalized(user.lastName)].filter((part) => part !== undefined).join(" ")
  return full.length > 0 ? full : (normalized(user.username) ?? "User")
}

/** The first name, else the username, else "User". For tight places like typing lines. */
export const userShortName = (user: UserNameFields | undefined): string =>
  normalized(user?.firstName) ?? normalized(user?.username) ?? "User"

/**
 * The avatar seed: first and last name ("User" standing in for a missing
 * first name), else the username without `@`, else "User". Drives initials
 * and the avatar color.
 */
export const userAvatarSeed = (user: UserNameFields | undefined): string => {
  const first = normalized(user?.firstName)
  const last = normalized(user?.lastName)
  if (first !== undefined || last !== undefined) return last !== undefined ? `${first ?? "User"} ${last}` : (first ?? "User")
  return normalizedUsername(user?.username) ?? "User"
}

/**
 * One uppercased grapheme from the seed, as the Mac shows. Undefined when the
 * user has no name or username at all: show a person symbol instead.
 */
export const userInitials = (user: UserNameFields | undefined): string | undefined => {
  if (normalized(user?.firstName) === undefined && normalized(user?.lastName) === undefined && normalized(user?.username) === undefined) {
    return undefined
  }
  const initial = firstGrapheme(userAvatarSeed(user)).toLocaleUpperCase()
  return initial.length > 0 ? initial : undefined
}

export const avatarPaletteSize = 12

/**
 * The avatar palette index for a seed: the sum of its UTF-8 bytes modulo the
 * palette size (`InlineAvatarStyle.paletteIndex`), so a user has the same
 * color on every client.
 */
export const avatarPaletteIndex = (seed: string, paletteSize: number = avatarPaletteSize): number => {
  if (paletteSize <= 0) return 0
  let sum = 0
  for (const byte of new TextEncoder().encode(seed)) sum = (sum + byte) % paletteSize
  return sum
}
