import CoreTransferable
import Foundation
import UniformTypeIdentifiers

public struct IncomingAttachmentTransfer: Transferable, Sendable {
  enum Payload: Sendable {
    case stagedFile(url: URL, cleanupDirectory: URL)
    case failure(PasteboardAttachmentFailure)
  }

  let payload: Payload

  public static var transferRepresentation: some TransferRepresentation {
    // Finder exposes every normal file as a small file-URL payload. Prefer it
    // so arbitrary documents keep their original filename and large files are
    // copied only once. Throwing on an unreadable URL lets Transferable try a
    // raw media/file-promise representation supplied by the same drag item.
    DataRepresentation(importedContentType: .fileURL) { data in
      try importFileURLData(data)
    }

    FileRepresentation(importedContentType: .image) { received in
      try importReceivedFile(received)
    }

    FileRepresentation(importedContentType: .movie) { received in
      try importReceivedFile(received)
    }

    FileRepresentation(importedContentType: .audio) { received in
      try importReceivedFile(received)
    }

    FileRepresentation(importedContentType: .pdf) { received in
      try importReceivedFile(received)
    }

    FileRepresentation(importedContentType: .archive) { received in
      try importReceivedFile(received)
    }

  }

  public func cleanup() {
    guard case let .stagedFile(_, cleanupDirectory) = payload else { return }
    try? FileManager.default.removeItem(at: cleanupDirectory)
  }

  private static func importFileURLData(_ data: Data) throws -> Self {
    guard let value = String(data: data, encoding: .utf8)?
      .trimmingCharacters(in: .whitespacesAndNewlines),
      let url = URL(string: value),
      url.isFileURL
    else {
      throw IncomingAttachmentTransferError.invalidFileURL
    }

    return try stageFile(at: url)
  }

  private static func importReceivedFile(_ received: ReceivedTransferredFile) throws -> Self {
    try stageFile(at: received.file)
  }

  private static func stageFile(at sourceURL: URL) throws -> Self {
    let sourceValues = try? sourceURL.resourceValues(forKeys: [
      .contentTypeKey,
      .isDirectoryKey,
      .isSymbolicLinkKey,
    ])
    if sourceValues?.isDirectory == true {
      return Self(payload: .failure(.directory(sourceURL)))
    }

    let copySource = sourceValues?.isSymbolicLink == true
      ? sourceURL.resolvingSymlinksInPath()
      : sourceURL
    let copySourceValues = try? copySource.resourceValues(forKeys: [
      .contentTypeKey,
      .isDirectoryKey,
    ])
    if copySourceValues?.isDirectory == true {
      return Self(payload: .failure(.directory(sourceURL)))
    }
    let hasSecurityScope = copySource.startAccessingSecurityScopedResource()
    defer {
      if hasSecurityScope {
        copySource.stopAccessingSecurityScopedResource()
      }
    }

    let fileManager = FileManager.default
    guard fileManager.fileExists(atPath: copySource.path),
          fileManager.isReadableFile(atPath: copySource.path)
    else {
      throw IncomingAttachmentTransferError.unreadableFile
    }

    let stagingDirectory = fileManager.temporaryDirectory
      .appendingPathComponent("inline-attachment-transfer-\(UUID().uuidString)", isDirectory: true)
    try fileManager.createDirectory(
      at: stagingDirectory,
      withIntermediateDirectories: true
    )

    do {
      let filename = stagedFilename(
        sourceURL: sourceURL,
        copySource: copySource,
        contentType: sourceValues?.contentType ?? copySourceValues?.contentType
      )
      let destinationURL = stagingDirectory.appendingPathComponent(filename)
      try fileManager.copyItem(at: copySource, to: destinationURL)
      return Self(payload: .stagedFile(
        url: destinationURL,
        cleanupDirectory: stagingDirectory
      ))
    } catch {
      try? fileManager.removeItem(at: stagingDirectory)
      throw error
    }
  }

  private static func stagedFilename(
    sourceURL: URL,
    copySource: URL,
    contentType: UTType?
  ) -> String {
    var filename = sourceURL.lastPathComponent
    if filename.isEmpty {
      filename = copySource.lastPathComponent
    }
    if filename.isEmpty {
      filename = UUID().uuidString
    }

    guard URL(fileURLWithPath: filename).pathExtension.isEmpty,
          let fileExtension = contentType?.preferredFilenameExtension
    else {
      return filename
    }
    return "\(filename).\(fileExtension)"
  }
}

private enum IncomingAttachmentTransferError: Error {
  case invalidFileURL
  case unreadableFile
}
