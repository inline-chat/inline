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
import { generateFileUniqueId } from "@in/server/modules/files/fileId"
import { FileTypes } from "@in/server/modules/files/types"
import { eq } from "drizzle-orm"

export const FileModel = {
  getFileByUniqueId: getFileByUniqueId,
  getPhotoById: getPhotoById,
  getVideoById: getVideoById,
  getDocumentById: getDocumentById,

  processFullPhoto: processFullPhoto,
  processFullVideo: processFullVideo,
  processFullDocument: processFullDocument,

  clonePhotoById: clonePhotoById,
  cloneVideoById: cloneVideoById,
  cloneDocumentById: cloneDocumentById,
}

export async function getFileByUniqueId(fileUniqueId: string): Promise<DbFile | undefined> {
  const [file] = await db.select().from(files).where(eq(files.fileUniqueId, fileUniqueId)).limit(1)
  return file
}

async function cloneFileFromExisting({
  file,
  newOwnerId,
  fileType,
}: {
  file: DbFile
  newOwnerId: number
  fileType: FileTypes
}): Promise<DbFile> {
  const fileUniqueId = generateFileUniqueId(fileType)
  const [newFile] = await db
    .insert(files)
    .values({
      fileUniqueId,
      userId: newOwnerId,
      pathEncrypted: file.pathEncrypted,
      pathIv: file.pathIv,
      pathTag: file.pathTag,
      fileSize: file.fileSize,
      mimeType: file.mimeType,
      cdn: file.cdn,
      fileType: file.fileType ?? fileType,
      videoDuration: file.videoDuration,
      thumbSize: file.thumbSize,
      thumbFor: file.thumbFor,
      bytesEncrypted: file.bytesEncrypted,
      bytesIv: file.bytesIv,
      bytesTag: file.bytesTag,
      nameEncrypted: file.nameEncrypted,
      nameIv: file.nameIv,
      nameTag: file.nameTag,
      width: file.width,
      height: file.height,
    })
    .returning()

  if (!newFile) {
    throw ModelError.Failed
  }

  return newFile
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
  let result = await db._query.photos.findFirst({
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

export async function clonePhotoById(photoId: number, newOwnerId: number): Promise<number> {
  const photo = await db._query.photos.findFirst({
    where: eq(photos.id, photoId),
    with: {
      photoSizes: {
        with: {
          file: true,
        },
      },
    },
  })

  if (!photo) {
    throw ModelError.PhotoInvalid
  }

  const [newPhoto] = await db
    .insert(photos)
    .values({
      format: photo.format,
      width: photo.width,
      height: photo.height,
      stripped: photo.stripped,
      strippedIv: photo.strippedIv,
      strippedTag: photo.strippedTag,
    })
    .returning()

  if (!newPhoto) {
    throw ModelError.PhotoInvalid
  }

  for (const size of photo.photoSizes ?? []) {
    if (!size.file) {
      continue
    }

    const newFile = await cloneFileFromExisting({
      file: size.file,
      newOwnerId,
      fileType: FileTypes.PHOTO,
    })

    await db.insert(photoSizes).values({
      fileId: newFile.id,
      photoId: newPhoto.id,
      size: size.size,
      width: size.width,
      height: size.height,
    })
  }

  return newPhoto.id
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
  const result = await db._query.videos.findFirst({
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

export async function cloneVideoById(videoId: number, newOwnerId: number): Promise<number> {
  const video = await db._query.videos.findFirst({
    where: eq(videos.id, videoId),
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

  if (!video || !video.file) {
    throw ModelError.VideoInvalid
  }

  const newFile = await cloneFileFromExisting({
    file: video.file,
    newOwnerId,
    fileType: FileTypes.VIDEO,
  })

  const newPhotoId = video.photo ? BigInt(await clonePhotoById(video.photo.id, newOwnerId)) : null

  const [newVideo] = await db
    .insert(videos)
    .values({
      fileId: newFile.id,
      photoId: newPhotoId,
      width: video.width,
      height: video.height,
      duration: video.duration,
    })
    .returning()

  if (!newVideo) {
    throw ModelError.VideoInvalid
  }

  return newVideo.id
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
  const result = await db._query.documents.findFirst({
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

export async function cloneDocumentById(documentId: number, newOwnerId: number): Promise<number> {
  const document = await db._query.documents.findFirst({
    where: eq(documents.id, documentId),
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

  if (!document || !document.file) {
    throw ModelError.DocumentInvalid
  }

  const newFile = await cloneFileFromExisting({
    file: document.file,
    newOwnerId,
    fileType: FileTypes.DOCUMENT,
  })

  const newPhotoId = document.photo ? BigInt(await clonePhotoById(document.photo.id, newOwnerId)) : null

  const [newDocument] = await db
    .insert(documents)
    .values({
      fileId: newFile.id,
      photoId: newPhotoId,
      fileName: document.fileName,
      fileNameIv: document.fileNameIv,
      fileNameTag: document.fileNameTag,
    })
    .returning()

  if (!newDocument) {
    throw ModelError.DocumentInvalid
  }

  return newDocument.id
}
