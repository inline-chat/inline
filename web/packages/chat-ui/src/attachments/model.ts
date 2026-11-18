/** A message's attachments as card models, in order. Unknown kinds are left out (the row flags them). */

import type { MessageRow } from "@inline/core-protocol"
import { externalTaskModel, type ExternalTaskModel } from "./external-task"
import { urlPreviewModel, type UrlPreviewModel, type UrlPreviewOptions } from "./url-preview"

export type AttachmentModel =
  | ({ readonly kind: "urlPreview" } & UrlPreviewModel)
  | ({ readonly kind: "externalTask" } & ExternalTaskModel)

export const attachmentModels = (
  row: Pick<MessageRow, "attachments">,
  options: UrlPreviewOptions = {},
): AttachmentModel[] => {
  const result: AttachmentModel[] = []
  for (const attachment of row.attachments ?? []) {
    if (attachment.kind === "urlPreview") result.push({ kind: "urlPreview", ...urlPreviewModel(attachment, options) })
    else if (attachment.kind === "externalTask") result.push({ kind: "externalTask", ...externalTaskModel(attachment) })
  }
  return result
}
