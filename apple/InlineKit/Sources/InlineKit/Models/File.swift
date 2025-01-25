import Foundation
import GRDB

public struct ApiPhoto: Codable, Hashable, Sendable {
  public var fileUniqueId: String
  public var width: Int
  public var height: Int
  public var fileSize: Int
  public var temporaryUrl: String
}

public enum MessageFileType: String, Codable, DatabaseValueConvertible, Sendable {
  case photo
  case file
  case video
}

public struct File: FetchableRecord, Identifiable, Codable, Hashable, PersistableRecord,
  TableRecord,
  Sendable, Equatable
{
  // Locally autoincremented id
  public var id: String

  // Raw message text from server
  public var fileUniqueId: String?

  // File type
  public var fileType: MessageFileType

  // Is uploading?
  public var uploading: Bool

  // File size
  public var fileSize: Int64

  // URL
  public var temporaryUrl: String?
  public var temporaryUrlExpiresAt: Date?

  public var width: Int?
  public var height: Int?

  // Local path
  public var localPath: String?

  public init(
    id: String,
    fileUniqueId: String?,
    fileType: MessageFileType,
    uploading: Bool,
    fileSize: Int64,
    temporaryUrl: String?,
    temporaryUrlExpiresAt: Date?,
    width: Int?,
    height: Int?,
    localPath: String?
  ) {
    self.id = id
    self.fileUniqueId = fileUniqueId
    self.fileType = fileType
    self.uploading = uploading
    self.fileSize = fileSize
    self.temporaryUrl = temporaryUrl
    self.temporaryUrlExpiresAt = temporaryUrlExpiresAt
    self.width = width
    self.height = height
    self.localPath = localPath
  }

  public init(fromAttachment attachment: SendMessageAttachment) {
    id = attachment.id
    uploading = true
    fileSize = attachment.fileSize
    localPath = attachment.filePath
    switch attachment.type {
      case let .photo(_, width, height):
        self.width = width
        self.height = height
        fileType = .photo
      default:
        fileType = .file // for now until we support more
    }

    // waiting for remote response to fill out
    fileUniqueId = nil
    temporaryUrl = nil
    temporaryUrlExpiresAt = nil
  }

  // TODO: from photo info
}

// Helpers
public extension File {
  func getLocalURL() -> URL? {
    guard let localPath else {
      return nil
    }
    return FileHelpers
      .getDocumentsDirectory()
      .appending(path: localPath)
  }
}
