export enum FileTypes {
  PHOTO = "photo",
  VIDEO = "video",
  DOCUMENT = "document",
}

export type FileType = FileTypes.PHOTO | FileTypes.VIDEO | FileTypes.DOCUMENT

export type UploadFileResult = {
  fileUniqueId: string

  photoId?: number
  videoId?: number
  documentId?: number
}
