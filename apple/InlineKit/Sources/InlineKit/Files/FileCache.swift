import Foundation
import Logger
import Nuke

#if os(iOS)
import UIKit
#else
import AppKit
#endif

public actor FileCache: Sendable {
  public static let shared = FileCache()

  private let database = AppDatabase.shared
  private let log = Log.scoped("FileCache")

  private init() {}

  // MARK: -  Fetches

  public static func getUrl(for dir: FileLocalCacheDirectory, localPath: String) -> URL {
    let directory = FileHelpers.getLocalCacheDirectory(for: dir)
    return directory.appendingPathComponent(localPath)
  }

  // MARK: -  Remote downloads

  public func download(photo: PhotoInfo, for message: Message) async {
    // TODO: Implement via Nuke for now?
    log.debug("downloading photo \(photo.id) for message \(message.id)")

    // For now we get thumbnail for size "f"
    guard let remoteUrl = photo.bestPhotoSize()?.cdnUrl else {
      log.warning("No remote URL found for photo")
      return
    }

    let request = ImageRequest(url: URL(string: remoteUrl))

    Task { @MainActor in
      ImagePipeline.shared.loadData(
        with: request,
        progress: { completed, total in
          Task {
            self.log.debug("progress \(completed) / \(total)")
          }
        },
        completion: { result in
          Task { [weak self] in
            guard let self else { return }
            switch result {
              case let .success(response):
                log.debug("success \(response)")

                // Generate a new file name
                let localPath = "IMG" + (photo.bestPhotoSize()?.type ?? "") + String(photo.id) +
                  photo.photo.format
                  .toExt()
                let localUrl = FileCache.getUrl(for: .photos, localPath: localPath)
                do {
                  try response.data.write(to: localUrl, options: .atomic)

                  Task { [weak self] in
                    guard let self else { return }
                    // Update database
                    try? await database.dbWriter.write { db in
                      guard var matchingSize = photo.bestPhotoSize() else { return }
                      matchingSize.localPath = localPath
                      try matchingSize.save(db)
                      self.log.debug("saved photo size \(matchingSize)")
                    }

                    await triggerMessageReload(message: message)
                  }
                } catch {
                  log.error("error saving image locally \(error)")
                }
              case let .failure(error):
                log.error("error \(error)")
            }
          }
        }
      )
    }
  }

  private func triggerMessageReload(message: Message) {
    Task { @MainActor in
      await MessagesPublisher.shared
        .messageUpdated(message: message, peer: message.peerId, animated: true)
    }
  }

  // MARK: - Local Saves

  public func savePhoto(image: PlatformImage) throws -> InlineKit.PhotoInfo {
    // Info
    let w = Int(image.size.width)
    let h = Int(image.size.height)
    let format: ImageFormat = hasAlphaChannel(image: image) ? .png : .jpeg
    let protoFormat = format.toProtocol()
    let ext = protoFormat.toExtension()
    let mimeType = protoFormat.toMimeType()
    let fileName = UUID().uuidString + ext

    // Save in files
    let directory = FileHelpers.getLocalCacheDirectory(for: .photos)
    guard let localPath = image.save(to: directory, withName: fileName, format: format)
    else { throw FileCacheError.failedToSave }
    let fileURL = directory.appendingPathComponent(
      localPath
    )
    let fileSize = FileHelpers.getFileSize(at: fileURL)

    // Save in DB
    let photoInfo = try database.dbWriter.write { db in
      try Photo.createLocalPhoto(
        db,
        format: format,
        localPath: localPath,
        fileSize: fileSize,
        width: w,
        height: h
      )
    }

    return photoInfo
  }

  public func saveVideo() throws -> InlineKit.VideoInfo {
    fatalError("Not implemented")
  }

  public func saveDocument() throws -> InlineKit.VideoInfo {
    fatalError("Not implemented")
  }
}

enum FileCacheError: Error {
  case failedToSave
  case failedToFetch
  case failedToRemove
}

// MARK: - Clear Cache

extension FileCache {
  public func clearCache() async throws {
    log.debug("Clearing cache")

    // Clear photos
    try await clearPhotoCache()
  }

  private func clearPhotoCache() async throws {
    // Step 1: Get all photo sizes with local paths from database
    let photoSizesWithLocalPaths = try await database.dbWriter.read { db in
      // Use the proper GRDB query syntax to filter non-null localPath values
      try PhotoSize.filter(sql: "localPath IS NOT NULL").fetchAll(db)
    }

    log.debug("Found \(photoSizesWithLocalPaths.count) cached photos to clear")

    // Step 2: Delete the actual files
    var deletedCount = 0
    var failedDeletions = 0

    for photoSize in photoSizesWithLocalPaths {
      guard let localPath = photoSize.localPath else { continue }

      let fileURL = FileCache.getUrl(for: .photos, localPath: localPath)

      do {
        // Check if file exists before attempting to delete
        if FileManager.default.fileExists(atPath: fileURL.path) {
          try FileManager.default.removeItem(at: fileURL)
          deletedCount += 1
        }
      } catch {
        failedDeletions += 1
        log.error("Failed to delete cached file at \(fileURL): \(error)")
      }
    }

    // Step 3: Clear local paths in database
    _ = try await database.dbWriter.write { db in
      try PhotoSize.updateAll(db, [PhotoSize.Columns.localPath.set(to: nil)])
    }

    log.info("Photo cache cleared: \(deletedCount) files deleted, \(failedDeletions) deletions failed")

    // Step 4: Clear the photos directory to catch any orphaned files
    try clearOrphanedFiles(in: .photos)
  }

  private func clearOrphanedFiles(in directory: FileLocalCacheDirectory) throws {
    let cacheDirectory = FileHelpers.getLocalCacheDirectory(for: directory)
    let fileManager = FileManager.default

    do {
      let fileURLs = try fileManager.contentsOfDirectory(
        at: cacheDirectory,
        includingPropertiesForKeys: nil
      )

      var deletedCount = 0
      var failedCount = 0

      for fileURL in fileURLs {
        do {
          try fileManager.removeItem(at: fileURL)
          deletedCount += 1
        } catch {
          failedCount += 1
          log.error("Failed to delete orphaned file at \(fileURL): \(error)")
        }
      }

      log.debug("Cleared orphaned files in \(directory) directory: \(deletedCount) deleted, \(failedCount) failed")
    } catch {
      log.error("Failed to enumerate files in \(directory) directory: \(error)")
      throw FileCacheError.failedToRemove
    }
  }
}
