export enum FileTypes {
  PHOTO = "photo",
  VIDEO = "video",
  DOCUMENT = "document",
  VOICE = "voice",
}

export type FileType = FileTypes.PHOTO | FileTypes.VIDEO | FileTypes.DOCUMENT | FileTypes.VOICE

export type UploadFileResult = {
  fileUniqueId: string

  photoId?: number
  videoId?: number
  documentId?: number
  voiceId?: number
}
