/**
 * File names in document rows truncate in the middle on the Mac
 * (`DocumentFileLayout`): the extension stays visible. CSS can only cut at the
 * end, so the view ellipsizes the stem and keeps the tail beside it.
 *
 * A file name is written by whoever sent the file. Bidirectional override,
 * embedding and isolate controls (U+202A to U+202E, U+2066 to U+2069) would
 * let `invoice\u202Efdp.exe` read as `invoiceexe.pdf`, so every name is shown
 * through `displayFileName`, which removes them (with control characters),
 * using chat-ui's preview rule. Views also draw the name in its own
 * direction-isolated element (`dir="auto"`), so it cannot reorder the text
 * around it.
 */

import { previewText } from "@inline/chat-ui"

/** Shown for a name that is empty once cleaned. */
export const UNNAMED_FILE = "File"

/** Long enough for any real file name (255 bytes on common file systems); only bounds the work. */
const maxNameGraphemes = 1024

/** A sender's file name made safe to show: no bidi controls, no control characters, one line. */
export const displayFileName = (name: string): string =>
  previewText(name, { maxGraphemes: maxNameGraphemes, fallback: UNNAMED_FILE })

/** The same, with path separators replaced, for a download's suggested name (`<a download>`, the save picker). */
export const downloadFileName = (name: string): string => displayFileName(name).replace(/[/\\]/g, "_")

export type FileNameParts = {
  /** Shrinks with an ellipsis. */
  readonly head: string
  /** Always shown: the last few characters of the stem and the extension. */
  readonly tail: string
}

/** Characters of the stem kept beside the extension. */
const tailStem = 3
const maxExtension = 10

/** Splits the cleaned name (`displayFileName`). */
export const splitFileName = (raw: string): FileNameParts => {
  const name = displayFileName(raw)
  const chars = Array.from(name)
  const dot = name.lastIndexOf(".")
  const extension = dot > 0 && name.length - dot - 1 <= maxExtension && dot < name.length - 1 ? name.slice(dot) : ""
  const stem = Array.from(extension ? name.slice(0, dot) : name)
  if (chars.length <= 16) return { head: name, tail: "" }
  const keep = Math.min(tailStem, Math.max(0, stem.length - 1))
  return { head: stem.slice(0, stem.length - keep).join(""), tail: stem.slice(stem.length - keep).join("") + extension }
}
