import type { FileTypes } from "@in/server/modules/files/types"
import { nanoid } from "nanoid/non-secure"

/**
 * Generate a file unique id for the given file type at 24 characters.
 *
 * @param type - The type of the file.
 * @returns A file unique id.
 */
export function generateFileUniqueId(type: FileTypes): string {
  return `IN${type.toUpperCase().at(0)}${nanoid(21)}` // eg. "INP12345678901234567890"
}
