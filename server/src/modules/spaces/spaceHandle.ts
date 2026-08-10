import { isReservedUsername } from "@in/server/modules/users/reservedUsernames"
import { normalizeUsername } from "@in/server/utils/normalize"

export const MAX_SPACE_HANDLE_LENGTH = 256

export function normalizeSpaceHandle(value: string): string | null {
  const handle = normalizeUsername(value)
  if (handle.length < 2 || handle.length > MAX_SPACE_HANDLE_LENGTH || isReservedUsername(handle)) {
    return null
  }
  return handle
}

export function isSpaceHandleUniqueError(error: unknown): boolean {
  if (!error || typeof error !== "object") return false

  const record = error as Record<string, unknown>
  return (
    record["code"] === "23505" &&
    (record["constraint"] === "spaces_handle_unique" ||
      record["constraint_name"] === "spaces_handle_unique" ||
      String(record["message"] ?? "").includes("spaces_handle_unique"))
  )
}
