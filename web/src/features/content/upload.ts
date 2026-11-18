/**
 * Rules for drawing a send's upload (`UploadOverlay`). Pure.
 */

import type { MessageState } from "@inline/core-protocol"
import type { UploadSourceState } from "./sources"

/** The ring never looks empty while something is happening (`PhotoUploadProgressView.minimumFraction`). */
export const MINIMUM_UPLOAD_FRACTION = 0.04

/** The fraction the ring shows for an upload's state: full once the bytes are all sent. */
export const ringFraction = (state: UploadSourceState): number => {
  if (state.phase === "complete" || state.phase === "processing") return 1
  return Math.max(MINIMUM_UPLOAD_FRACTION, Math.min(1, state.fraction ?? 0))
}

/** Whether a row in this state draws an upload control: the ring with "Cancel Upload", or "Resend". */
export const showsUpload = (state: MessageState): boolean => state === "sending" || state === "failed"
