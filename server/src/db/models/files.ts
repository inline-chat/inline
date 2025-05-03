import { db } from "@in/server/db"
import { ModelError } from "@in/server/db/models/_errors"
import {
  documents,
  files,
  photos,
  photoSizes,
  videos,
  type DbDocument,
  type DbFile,
  type DbPhoto,
  type DbPhotoSize,
  type DbVideo,
} from "@in/server/db/schema"
import { decrypt } from "@in/server/modules/encryption/encryption"
import { eq } from "drizzle-orm"

export const FileModel = {
  getFileByUniqueId: getFileByUniqueId,
  getPhotoById: getPhotoById,
  getVideoById: getVideoById,
  getDocumentById: getDocumentById,

  processFullPhoto: processFullPhoto,
  processFullVideo: processFullVideo,
  processFullDocument: processFullDocument,
}

export async function getFileByUniqueId(fileUniqueId: string): Promise<DbFile | undefined> {
  const [file] = await db.select().from(files).where(eq(files.fileUniqueId, fileUniqueId)).limit(1)
  return file
}

// From drizzle
export type InputDbFullPhoto = DbPhoto & {
  photoSizes: InputDbFullPhotoSize[] | null
}
export type InputDbFullPhotoSize = DbPhotoSize & {
  file: DbFile | null
}

// After processing
export type DbFullPhoto = DbPhoto & {
  photoSizes: DbFullPhotoSize[] | null
}
export type DbFullPhotoSize = DbPhotoSize & {
  file: DbFullPlainFile
}
export type DbFullPlainFile = Omit<DbFile, "pathEncrypted" | "pathIv" | "pathTag"> & {
  path: string | null
}

/** Filter, normalize and decrypt */
function processFile(file: DbFile): DbFullPlainFile {
  return {
    ...file,
    path:
      file.pathEncrypted && file.pathIv && file.pathTag
        ? decrypt({ encrypted: file.pathEncrypted, iv: file.pathIv, authTag: file.pathTag })
        : null,
  }
}

/** Filter, normalize and decrypt */
export function processFullPhoto(photo: InputDbFullPhoto): DbFullPhoto {
  let processed: DbFullPhoto = {
    ...photo,
    photoSizes: photo.photoSizes
      ?.map((size) => {
        if (!size.file) {
          return null
        }

        return {
          ...size,
          file: processFile(size.file),
        }
      })
      .filter((size) => size !== null) as DbFullPhotoSize[],
  }
  return processed
}

async function getPhotoById(photoId: bigint): Promise<DbFullPhoto | undefined> {
  let result = await db.query.photos.findFirst({
    where: eq(photos.id, Number(photoId)),
    with: {
      photoSizes: {
        with: {
          file: true,
        },
      },
    },
  })

  if (!result) {
    throw ModelError.PhotoInvalid
  }

  return processFullPhoto(result)
}

export type InputDbFullVideo = DbVideo & {
  file: DbFile | null
  photo: InputDbFullPhoto | null
}

function processFullVideo(video: InputDbFullVideo): DbFullVideo {
  if (!video.file) {
    throw ModelError.VideoInvalid
  }

  let processed: DbFullVideo = {
    ...video,
    file: processFile(video.file),
    photo: video.photo ? processFullPhoto(video.photo) : null,
  }

  return processed
}

export type DbFullVideo = DbVideo & {
  file: DbFullPlainFile
  photo: DbFullPhoto | null
}

async function getVideoById(videoId: bigint): Promise<DbFullVideo | undefined> {
  const result = await db.query.videos.findFirst({
    where: eq(videos.id, Number(videoId)),
    with: {
      file: true,
      photo: {
        with: {
          photoSizes: {
            with: {
              file: true,
            },
          },
        },
      },
    },
  })

  if (!result) {
    throw ModelError.VideoInvalid
  }

  return processFullVideo(result)
}

export type InputDbFullDocument = DbDocument & {
  file: DbFile | null
}

function processFullDocument(document: InputDbFullDocument): DbFullDocument {
  if (!document.file) {
    throw ModelError.DocumentInvalid
  }

  return {
    ...document,
    fileName:
      document.fileName && document.fileNameIv && document.fileNameTag
        ? decrypt({ encrypted: document.fileName, iv: document.fileNameIv, authTag: document.fileNameTag })
        : null,
    file: processFile(document.file),
  }
}

// Decrypted
export type DbPlainDocument = Omit<DbDocument, "fileName" | "fileNameIv" | "fileNameTag"> & {
  fileName: string | null
}
export type DbFullDocument = DbPlainDocument & {
  file: DbFullPlainFile
}

async function getDocumentById(documentId: bigint): Promise<DbFullDocument | undefined> {
  const result = await db.query.documents.findFirst({
    where: eq(documents.id, Number(documentId)),
    with: {
      file: true,
    },
  })

  if (!result) {
    throw ModelError.DocumentInvalid
  }

  return processFullDocument(result)
}
