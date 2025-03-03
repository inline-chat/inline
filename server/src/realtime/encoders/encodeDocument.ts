import { getSignedUrl } from "@in/server/modules/files/path"
import { Document } from "@in/protocol/core"
import type { DbFullDocument } from "@in/server/db/models/files"

const defaultMimeType = "application/octet-stream"

export const encodeDocument = ({ document }: { document: DbFullDocument }) => {
  let proto: Document = {
    id: BigInt(document.id),
    date: BigInt(document.date.getTime() / 1000),
    size: document.file.fileSize ?? 0,
    mimeType: document.file.mimeType ?? defaultMimeType,
    fileName: document.fileName ?? "",
    cdnUrl: document.file?.path ? getSignedUrl(document.file.path) ?? undefined : undefined,
  }

  return proto
}
