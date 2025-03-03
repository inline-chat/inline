import { FileTypes, type UploadFileResult } from "@in/server/modules/files/types"
import { documents } from "@in/server/db/schema"
import { db } from "@in/server/db"
import { uploadFile } from "./uploadAFile"
import { encrypt } from "@in/server/modules/encryption/encryption"
import { getDocumentMetadataAndValidate } from "@in/server/modules/files/metadata"

export async function uploadDocument(
  file: File,
  photoId: bigint | undefined,
  context: { userId: number },
): Promise<UploadFileResult> {
  const metadata = await getDocumentMetadataAndValidate(file)
  const { dbFile, fileUniqueId } = await uploadFile(file, FileTypes.DOCUMENT, metadata, context)

  // Encrypt the file name for documents table
  const encryptedFileName = encrypt(metadata.fileName)

  // Save document metadata
  const [document] = await db
    .insert(documents)
    .values({
      fileId: dbFile.id,
      fileName: encryptedFileName.encrypted,
      fileNameIv: encryptedFileName.iv,
      fileNameTag: encryptedFileName.authTag,
      photoId: photoId,
      date: new Date(),
    })
    .returning()

  if (!document) {
    throw new Error("Failed to save document to DB")
  }

  return { fileUniqueId, documentId: document.id }
}
