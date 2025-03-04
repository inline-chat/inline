import Foundation
import GRDB
import InlineProtocol
import Logger
import MultipartFormDataKit

#if canImport(AppKit)
import AppKit
#endif

#if canImport(UIKit)
import UIKit
#endif

public struct UploadResult: Sendable {
  public var photoId: Int64?
  public var videoId: Int64?
  public var documentId: Int64?
}

public actor FileUploader {
  public static let shared = FileUploader()

  private init() {}

  // [uploadId: Task]
  private var uploadTasks: [String: Task<UploadResult, Never>] = [:]

  // [uploadId: UploadResult] cached results if task was finished
  private var finishedUploads: [String: UploadResult] = [:]

  // [localId: ProgressHandler]
  private var progressHandlers: [String: (Double) -> Void] = [:]

  // MARK: - Wait for Upload

  public func waitForUpload(photoLocalId id: Int64) async -> UploadResult? {
    await waitForUpload(uploadId: getUploadId(photoId: id))
  }

  public func waitForUpload(videoLocalId id: Int64) async -> UploadResult? {
    await waitForUpload(uploadId: getUploadId(videoId: id))
  }

  public func waitForUpload(documentLocalId id: Int64) async -> UploadResult? {
    await waitForUpload(uploadId: getUploadId(documentId: id))
  }

  private func waitForUpload(uploadId: String) async -> UploadResult? {
    if let task = uploadTasks[uploadId] {
      // still in progress
      return await task.value
    } else if let result = finishedUploads[uploadId] {
      // finished
      return result
    } else {
      // not found
      Log.shared.warning("Upload not found")
      return UploadResult(photoId: nil, videoId: nil, documentId: nil)
    }
  }

  // MARK: - Upload

  public func uploadPhoto(
    photoInfo: PhotoInfo
  ) throws -> Int64 {
    let photoSize = photoInfo.bestPhotoSize()
    guard let photoSize,
          let localPath = photoSize.localPath
    else {
      throw FileUploadError.invalidPhoto
    }
    let localUrl = FileHelpers.getLocalCacheDirectory(for: .photos).appendingPathComponent(
      localPath
    )
    let format = photoInfo.photo.format ?? .jpeg
    let size = FileHelpers.getFileSize(at: localUrl)
    let ext = format.toExt()
    let fileName = localPath.components(separatedBy: "/").last ?? "" + ext
    let mimeType = format.toMimeType()

    try startUpload(
      media: .photo(photoInfo),
      localUrl: localUrl,
      mimeType: mimeType,
      fileName: fileName
    )

    guard let localPhotoId = photoInfo.photo.id else { throw FileUploadError.invalidPhotoId }

    return localPhotoId
  }

  public func uploadVideo(
    videoInfo: VideoInfo
  ) async throws -> Int64 {
    // todo
    0
  }

  public func uploadDocument(
    documentInfo: DocumentInfo
  ) async throws -> Int64 {
    // todo
    0
  }

//  private func uploadFile() async throws -> UploadResult {
//    // todo
//  }

  struct UploadHandle {}

  public func startUpload(
    media: FileMediaItem,
    localUrl: URL,
    mimeType: String,
    fileName: String
  ) throws {
    let type: MessageFileType
    let uploadId: String

    switch media {
      case let .photo(photoInfo):
        uploadId = getUploadId(photoId: photoInfo.photo.id!)
        type = .photo
      case let .video(videoInfo):
        uploadId = getUploadId(videoId: videoInfo.video.id!)
        type = .video
      case let .document(documentInfo):
        uploadId = getUploadId(documentId: documentInfo.document.id!)
        type = .file
    }

    let task = Task<UploadResult, Never> {
      do {
        // get data from file
        let data = try Data(contentsOf: localUrl)

        // upload file
        let result = try await ApiClient.shared
          .uploadFile(
            type: type,
            data: data,
            filename: fileName,
            mimeType: MIMEType(text: mimeType)
          ) { _ in
            // TODO: progresss
          }

        // return IDs
        let result_ = UploadResult(
          photoId: result.photoId,
          videoId: result.videoId,
          documentId: result.documentId
        )

        // Store
        finishedUploads[uploadId] = result_

        // Update database with new ID
        do {
          switch media {
            case let .photo(photoInfo):
              if let serverId = result.photoId {
                try await AppDatabase.shared.dbWriter.write { db in
                  try AppDatabase.updatePhotoWithServerId(db, localPhoto: photoInfo.photo, serverId: serverId)
                }
              }
            case let .video(videoInfo):
              if let serverId = result.videoId {
                try await AppDatabase.shared.dbWriter.write { db in
                  try AppDatabase.updateVideoWithServerId(db, localVideo: videoInfo.video, serverId: serverId)
                }
              }

            case let .document(documentInfo):
              if let serverId = result.documentId {
                try await AppDatabase.shared.dbWriter.write { db in
                  try AppDatabase.updateDocumentWithServerId(
                    db,
                    localDocument: documentInfo.document,
                    serverId: serverId
                  )
                }
              }
          }
        } catch {
          Log.shared.error("Failed to update database with new server ID", error: error)
        }

        // Remove from tasks
        Task {
          self.uploadTasks.removeValue(forKey: uploadId)
        }

        return result_
      } catch {
        return UploadResult(photoId: nil, videoId: nil, documentId: nil)
      }
    }

    // store task
    uploadTasks[uploadId] = task
  }

  private func cancel(uploadId: String) {
    // todo
  }

  private func getUploadId(photoId: Int64) -> String {
    "photo_\(photoId)"
  }

  private func getUploadId(videoId: Int64) -> String {
    "video_\(videoId)"
  }

  private func getUploadId(documentId: Int64) -> String {
    "document_\(documentId)"
  }
}

public enum FileUploadError: Error {
  case invalidPhoto
  case invalidVideo
  case invalidDocument
  case invalidPhotoId
}
