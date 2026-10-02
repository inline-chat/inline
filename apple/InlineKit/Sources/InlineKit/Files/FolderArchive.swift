import Foundation
import ZIPFoundation

/// Creates an owned ZIP archive. Call from an attachment worker, never from
/// the UI thread. The caller must remove the returned URL's parent directory.
public enum FolderArchive {
  public static func createIfDirectory(at sourceURL: URL) throws -> URL? {
    try Task.checkCancellation()
    let hasSecurityScope = sourceURL.startAccessingSecurityScopedResource()
    defer {
      if hasSecurityScope { sourceURL.stopAccessingSecurityScopedResource() }
    }

    let source = sourceURL.resolvingSymlinksInPath()
    let values = try source.resourceValues(forKeys: [.isDirectoryKey])
    guard values.isDirectory == true else { return nil }

    let fileManager = FileManager.default
    let directory = fileManager.temporaryDirectory
      .appendingPathComponent("inline-folder-\(UUID().uuidString)", isDirectory: true)
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    let name = sourceURL.lastPathComponent.isEmpty ? "Folder" : sourceURL.lastPathComponent
    let destination = directory.appendingPathComponent(name + ".zip")

    do {
      var coordinationError: NSError?
      var archiveError: Error?
      var didArchive = false
      NSFileCoordinator().coordinate(
        readingItemAt: source,
        options: .withoutChanges,
        error: &coordinationError
      ) { coordinatedSource in
        do {
          try Task.checkCancellation()
          try writeArchive(from: coordinatedSource, named: name, to: destination)
          didArchive = true
        } catch {
          archiveError = error
        }
      }
      if let coordinationError { throw coordinationError }
      if let archiveError { throw archiveError }
      guard didArchive else { throw CocoaError(.fileReadUnknown) }
      try Task.checkCancellation()
      return destination
    } catch {
      try? fileManager.removeItem(at: directory)
      throw error
    }
  }

  private static func writeArchive(from source: URL, named name: String, to destination: URL) throws {
    let archive = try Archive(url: destination, accessMode: .create)
    let outputDirectory = destination.deletingLastPathComponent().resolvingSymlinksInPath()
    // Include the root even when the selected folder is completely empty.
    try archive.addEntry(with: name + "/", fileURL: source)
    var enumerationError: Error?
    guard let entries = FileManager.default.enumerator(
      at: source,
      includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
      errorHandler: { _, error in
        enumerationError = error
        return false
      }
    ) else { throw CocoaError(.fileReadUnknown) }

    for case let url as URL in entries {
      try Task.checkCancellation()
      // Selecting an ancestor of the temporary directory must not archive our own output.
      if url.resolvingSymlinksInPath() == outputDirectory {
        entries.skipDescendants()
        continue
      }
      let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
      guard values.isDirectory == true || values.isRegularFile == true || values.isSymbolicLink == true else {
        throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: url.path])
      }
      // Enumeration does not follow symlinks. Use its depth because coordinated
      // and enumerated URLs can spell the same root as /var or /private/var.
      let relativePath = url.pathComponents.suffix(entries.level).joined(separator: "/")
      // addEntry stores link text, rather than traversing links outside the selected folder.
      try archive.addEntry(with: name + "/" + relativePath, fileURL: url, compressionMethod: .deflate)
    }
    if let enumerationError { throw enumerationError }
  }
}
