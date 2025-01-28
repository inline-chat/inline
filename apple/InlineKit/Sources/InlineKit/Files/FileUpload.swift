import Foundation
import GRDB
import InlineKit
import MultipartFormDataKit

public struct UploadResult: Sendable {
  public var fileUniqueId: String
}

public actor FileUploader {
  public static let shared = FileUploader()

  private init() {}

  // [localId: Task]
  private var uploadTasks: [String: Task<UploadResult, Error>] = [:]

  // MARK: - Upload

  public func upload(
    localId: String,
    type: MessageFileType,
    path: String,
    filename: String,
    mimeType: String
  ) async throws -> UploadResult {
    let task = Task {
      // construct full path
      let fullPath = FileHelpers.getDocumentsDirectory().appendingPathComponent(path)

      // get data from file
      let data = try Data(contentsOf: fullPath)

      // update file entry in database
      let _ = try? await AppDatabase.shared.dbWriter.write { db in
        try File.filter(id: localId).updateAll(db, Column("uploading").set(to: true))
      }

      // upload file
      let result = try await ApiClient.shared
        .uploadFile(
          type: type,
          data: data,
          filename: filename,
          mimeType: MIMEType(text: mimeType)
        ) { _ in
          // TO=DO:
        }

      // return ID
      return UploadResult(fileUniqueId: result.fileUniqueId)
    }

    // store task so we can cancel
    uploadTasks[localId] = task

    // not sure what i'm doing here
    let result = try await task.result.get()

    // TODO: better mem clearing for failed stuff
    uploadTasks.removeValue(forKey: localId)

    return result
  }

  public func cancel(localId: String) {
    // todo
  }
}
