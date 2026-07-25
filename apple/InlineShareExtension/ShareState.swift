import Auth
import AVFoundation
import Foundation
import ImageIO
import InlineIntents
import InlineKit
import InlineProtocol
import Logger
import MultipartFormDataKit
import SwiftUI
import UniformTypeIdentifiers

struct SendableItemProvider: @unchecked Sendable {
  let provider: NSItemProvider
}

enum SharedFileSource: @unchecked Sendable {
  case itemProvider(SendableItemProvider, typeIdentifier: String)
  case fileURL(URL)
}

/// Represents a staged file that was shared through the extension.
struct SharedFile: Identifiable, @unchecked Sendable {
  let id = UUID()
  let source: SharedFileSource
  let fileName: String
  let typeIdentifier: String?
  let mimeType: MIMEType
  let fileType: MessageFileType
  let fileSize: Int64?
  let isAnimatedImage: Bool
}

/// Aggregated shared content from the extension.
struct SharedContent: @unchecked Sendable {
  var files: [SharedFile] = []
  var urls: [URL] = []
  var textParts: [String] = []

  var hasMedia: Bool { !files.isEmpty }
  var hasText: Bool { textParts.contains { !$0.isEmpty } }
  var hasUrls: Bool { !urls.isEmpty }
  var mediaCount: Int { files.count }

  var photoCount: Int { files.filter { $0.fileType == .photo }.count }
  var videoCount: Int { files.filter { $0.fileType == .video }.count }
  var documentCount: Int { files.filter { $0.fileType == .document }.count }

  var totalItemCount: Int {
    var count = mediaCount + urls.count
    if hasText { count += 1 }
    return count
  }

  var combinedText: String? {
    let parts = textParts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    guard !parts.isEmpty else { return nil }
    return parts.joined(separator: "\n\n")
  }

  var summaryTitle: String {
    if photoCount > 0, videoCount == 0, documentCount == 0, !hasText, !hasUrls {
      return "\(photoCount) photo\(photoCount == 1 ? "" : "s")"
    }
    if videoCount > 0, photoCount == 0, documentCount == 0, !hasText, !hasUrls {
      return "\(videoCount) video\(videoCount == 1 ? "" : "s")"
    }
    if documentCount > 0, photoCount == 0, videoCount == 0, !hasText, !hasUrls {
      return "\(documentCount) file\(documentCount == 1 ? "" : "s")"
    }
    if hasUrls, !hasMedia, !hasText {
      return "\(urls.count) link\(urls.count == 1 ? "" : "s")"
    }
    if hasText, !hasMedia, !hasUrls {
      return "Message"
    }
    return "\(totalItemCount) item\(totalItemCount == 1 ? "" : "s")"
  }

  var summaryDetail: String {
    var parts: [String] = []
    if photoCount > 0 { parts.append("\(photoCount) photo\(photoCount == 1 ? "" : "s")") }
    if videoCount > 0 { parts.append("\(videoCount) video\(videoCount == 1 ? "" : "s")") }
    if documentCount > 0 { parts.append("\(documentCount) file\(documentCount == 1 ? "" : "s")") }
    if hasUrls { parts.append("\(urls.count) link\(urls.count == 1 ? "" : "s")") }
    if hasText { parts.append("text") }
    return parts.isEmpty ? "Ready to share" : parts.joined(separator: " + ")
  }
}

private final class SharedContentAccumulator: @unchecked Sendable {
  private let lock = NSLock()
  private let maxMedia: Int
  private let maxUrls: Int

  private(set) var files: [SharedFile] = []
  private(set) var urls: [URL] = []
  private(set) var textParts: [String] = []

  init(maxMedia: Int, maxUrls: Int) {
    self.maxMedia = maxMedia
    self.maxUrls = maxUrls
  }

  @discardableResult
  func addFile(_ file: SharedFile) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard files.count < maxMedia else { return false }
    files.append(file)
    return true
  }

  func addURL(_ url: URL) {
    lock.lock()
    defer { lock.unlock() }
    guard urls.count < maxUrls else { return }
    guard !urls.contains(where: { $0.absoluteString == url.absoluteString }) else { return }
    urls.append(url)
  }

  func addText(_ text: String) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    lock.lock()
    defer { lock.unlock() }
    guard !textParts.contains(trimmed) else { return }
    textParts.append(trimmed)
  }

  func finalize() -> SharedContent {
    lock.lock()
    defer { lock.unlock() }
    return SharedContent(files: files, urls: urls, textParts: textParts)
  }
}

/// Resolves a non-cancellable realtime invocation or its local deadline exactly once.
private final class SendMessageInvocationGate: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<RpcResult.OneOf_Result?, any Error>?

  init(continuation: CheckedContinuation<RpcResult.OneOf_Result?, any Error>) {
    self.continuation = continuation
  }

  func resume(with result: Result<RpcResult.OneOf_Result?, any Error>) {
    lock.lock()
    guard let continuation else {
      lock.unlock()
      return
    }
    self.continuation = nil
    lock.unlock()
    continuation.resume(with: result)
  }
}

/// Manages the state and operations for the share extension
/// Handles loading shared content, uploading files, and sending messages
@MainActor
class ShareState: ObservableObject {
  private nonisolated static let maxMedia = 10
  private nonisolated static let maxUrls = 10
  private nonisolated static let imageCompressionQuality: CGFloat = 0.52
  private nonisolated static let maxPhotoUploadDimension = 1280
  private nonisolated static let photoOptimizationThresholdBytes = 1_500_000
  private nonisolated static let maxFileSizeBytes: Int64 = 100 * 1024 * 1024
  private nonisolated static let maxVideoFileSizeBytes: Int64 = maxFileSizeBytes
  private nonisolated static func maxFileSizeDisplay(for bytes: Int64) -> String {
    let gib: Int64 = 1024 * 1024 * 1024
    let mib: Int64 = 1024 * 1024
    if bytes % gib == 0 {
      return "\(bytes / gib)GB"
    }
    if bytes % mib == 0 {
      return "\(bytes / mib)MB"
    }
    return "\(bytes) bytes"
  }

  private struct TemporarySharedFile {
    let url: URL
    let fileName: String
    let typeIdentifier: String?
    let fileType: MessageFileType
    let cleanupURLs: [URL]
  }

  private struct PreparedSharedFile {
    let url: URL
    let fileName: String
    let mimeType: MIMEType
    let fileType: MessageFileType
    let fileSize: Int64
    let isAnimatedImage: Bool
    let videoMetadata: ApiClient.VideoUploadMetadata?
    let cleanupURLs: [URL]
  }

  @Published var sharedContent: SharedContent?
  @Published var sharedData: SharedData?
  @Published var isLoadingContent: Bool = false
  @Published var isSending: Bool = false
  @Published var isSent: Bool = false
  @Published var uploadProgress: Double = 0
  @Published var errorState: ErrorState?
  @Published var sendProgress = ShareProgressState.idle
  @Published var contentWarnings: [String] = []

  private nonisolated let log = Log.scoped("ShareState")
  private nonisolated let shareSessionId = UUID().uuidString
  private nonisolated let realtimeConnectWarmupSeconds: TimeInterval = 2
  private nonisolated let realtimeConnectRetrySeconds: TimeInterval = 8
  private nonisolated let sendTimeoutSeconds: TimeInterval = 12
  @MainActor private var hasStartedRealtime: Bool = false

  private nonisolated func tagged(_ message: String) -> String {
    "[share \(shareSessionId)] \(message)"
  }

  private nonisolated func logValue(_ value: String?) -> String {
    guard let value, !value.isEmpty else { return "none" }
    return value
  }

  private nonisolated func fileSizeLogValue(_ fileSize: Int64?) -> String {
    fileSize.map(String.init) ?? "unknown"
  }

  private nonisolated func sourceLogValue(for source: SharedFileSource) -> String {
    switch source {
    case .itemProvider:
      return "itemProvider"
    case .fileURL:
      return "fileURL"
    }
  }

  private nonisolated func uploadResultLogValue(_ result: InlineKit.UploadFileResult) -> String {
    var parts: [String] = []
    if let photoId = result.photoId { parts.append("photoId=\(photoId)") }
    if let videoId = result.videoId { parts.append("videoId=\(videoId)") }
    if let documentId = result.documentId { parts.append("documentId=\(documentId)") }
    if let voiceId = result.voiceId { parts.append("voiceId=\(voiceId)") }
    return parts.isEmpty ? "no-media-id" : parts.joined(separator: " ")
  }

  private nonisolated func resolveMimeType(
    fileURL: URL?,
    suggestedName: String?,
    typeIdentifier: String?
  ) -> MIMEType {
    if let typeIdentifier,
       let utType = UTType(typeIdentifier),
       let mime = utType.preferredMIMEType
    {
      return MIMEType(text: mime)
    }

    if let suggestedName {
      let ext = (suggestedName as NSString).pathExtension.lowercased()
      if !ext.isEmpty,
         let utType = UTType(filenameExtension: ext),
         let mime = utType.preferredMIMEType
      {
        return MIMEType(text: mime)
      }
    }

    if let fileURL,
       let contentType = try? fileURL.resourceValues(forKeys: [.contentTypeKey]).contentType,
       let mime = contentType.preferredMIMEType
    {
      return MIMEType(text: mime)
    }

    if let fileURL {
      return MIMEType(text: FileHelpers.getMimeType(for: fileURL))
    }

    return MIMEType(text: "application/octet-stream")
  }

  private nonisolated func shouldTranscodePhotoToJpeg(
    suggestedName: String?,
    typeIdentifier: String?,
    mimeType: MIMEType?
  ) -> Bool {
    if let typeIdentifier,
       let utType = UTType(typeIdentifier),
       utType.conforms(to: .heic) || utType.conforms(to: .heif)
    {
      return true
    }

    if let suggestedName {
      let ext = (suggestedName as NSString).pathExtension.lowercased()
      if ext == "heic" || ext == "heif" {
        return true
      }
    }

    if let mimeType {
      let lowercased = mimeType.text.lowercased()
      if lowercased == "image/heic" ||
         lowercased == "image/heif" ||
         lowercased == "image/heic-sequence" ||
         lowercased == "image/heif-sequence"
      {
        return true
      }
    }

    return false
  }

  private nonisolated func jpegFileName(from fileName: String?) -> String {
    let baseName = (fileName ?? "shared_image") as NSString
    let stem = baseName.deletingPathExtension
    let safeStem = stem.isEmpty ? "shared_image" : stem
    return "\(safeStem).jpg"
  }

  private nonisolated func imageSourceReadOptions() -> CFDictionary {
    [kCGImageSourceShouldCache: false] as CFDictionary
  }

  private nonisolated func writeThumbnailJpeg(from source: CGImageSource, to destinationURL: URL) -> Bool {
    autoreleasepool {
      let options: [CFString: Any] = [
        kCGImageSourceShouldCache: false,
        kCGImageSourceShouldCacheImmediately: true,
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: Self.maxPhotoUploadDimension,
      ]
      guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
            let destination = CGImageDestinationCreateWithURL(
              destinationURL as CFURL,
              UTType.jpeg.identifier as CFString,
              1,
              nil
            )
      else {
        return false
      }
      let properties: [CFString: Any] = [
        kCGImageDestinationLossyCompressionQuality: Self.imageCompressionQuality,
      ]
      CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
      return CGImageDestinationFinalize(destination)
    }
  }

  private nonisolated func jpegData(
    from cgImage: CGImage,
    compressionQuality: CGFloat = ShareState.imageCompressionQuality
  ) -> Data? {
    autoreleasepool {
      let data = NSMutableData()
      guard let destination = CGImageDestinationCreateWithData(
        data,
        UTType.jpeg.identifier as CFString,
        1,
        nil
      ) else {
        return nil
      }
      let properties: [CFString: Any] = [
        kCGImageDestinationLossyCompressionQuality: compressionQuality,
      ]
      CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
      guard CGImageDestinationFinalize(destination) else { return nil }
      return data as Data
    }
  }

  private nonisolated func photoPixelSize(from url: URL) -> CGSize? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, imageSourceReadOptions()) else {
      return nil
    }
    return photoPixelSize(from: source)
  }

  private nonisolated func photoPixelSize(from source: CGImageSource) -> CGSize? {
    guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, imageSourceReadOptions()) as? [CFString: Any] else {
      return nil
    }

    guard let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
          let height = properties[kCGImagePropertyPixelHeight] as? NSNumber
    else {
      return nil
    }
    return CGSize(width: CGFloat(truncating: width), height: CGFloat(truncating: height))
  }

  private nonisolated func optimizedPhotoUploadFile(
    from url: URL,
    suggestedName: String?,
    cleanupURLs: [URL]
  ) throws -> PreparedSharedFile? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, imageSourceReadOptions()),
          let pixelSize = photoPixelSize(from: source)
    else {
      return nil
    }

    let fileSize = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
    let largestDimension = max(pixelSize.width, pixelSize.height)
    let shouldOptimize = largestDimension > CGFloat(Self.maxPhotoUploadDimension) ||
      (fileSize ?? 0) > Self.photoOptimizationThresholdBytes
    guard shouldOptimize else { return nil }

    return try downsampledPhotoFile(
      from: source,
      fileName: jpegFileName(from: suggestedName),
      cleanupURLs: cleanupURLs,
      originalFileSize: fileSize.map { Int64($0) }
    )
  }

  private nonisolated func downsampledPhotoFile(
    from url: URL,
    fileName: String,
    cleanupURLs: [URL]
  ) throws -> PreparedSharedFile? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, imageSourceReadOptions()) else {
      return nil
    }
    return try downsampledPhotoFile(
      from: source,
      fileName: fileName,
      cleanupURLs: cleanupURLs,
      originalFileSize: nil
    )
  }

  private nonisolated func downsampledPhotoFile(
    from source: CGImageSource,
    fileName: String,
    cleanupURLs: [URL],
    originalFileSize: Int64?
  ) throws -> PreparedSharedFile? {
    let tempURL = temporaryURL(
      suggestedName: fileName,
      typeIdentifier: UTType.jpeg.identifier
    )
    guard writeThumbnailJpeg(from: source, to: tempURL) else {
      try? FileManager.default.removeItem(at: tempURL)
      return nil
    }

    let size = fileSize(for: tempURL) ?? 0
    if let originalFileSize, size >= originalFileSize {
      try? FileManager.default.removeItem(at: tempURL)
      return nil
    }

    return PreparedSharedFile(
      url: tempURL,
      fileName: sanitizedFileName(
        suggestedName: fileName,
        fallbackURL: tempURL,
        typeIdentifier: UTType.jpeg.identifier
      ),
      mimeType: MIMEType(text: "image/jpeg"),
      fileType: .photo,
      fileSize: size,
      isAnimatedImage: false,
      videoMetadata: nil,
      cleanupURLs: cleanupURLs + [tempURL]
    )
  }

  private nonisolated func shouldSendPhotoAsDocument(at url: URL) -> Bool {
    guard let pixelSize = photoPixelSize(from: url) else { return false }
    let width = max(pixelSize.width, 1)
    let height = max(pixelSize.height, 1)
    let ratio = max(width / height, height / width)
    return ratio > 20 || (width < 50 && height < 50)
  }

  private nonisolated func isSupportedPhotoMimeType(_ mimeType: MIMEType) -> Bool {
    let lowercased = mimeType.text.lowercased()
    return lowercased == "image/jpeg" || lowercased == "image/png" || lowercased == "image/gif"
  }

  private nonisolated func shouldOptimizePhotoUpload(mimeType: MIMEType) -> Bool {
    let lowercased = mimeType.text.lowercased()
    return lowercased == "image/jpeg" || lowercased == "image/jpg"
  }

  private nonisolated func isGIF(
    suggestedName: String?,
    typeIdentifier: String?,
    mimeType: MIMEType?
  ) -> Bool {
    if let typeIdentifier,
       let utType = UTType(typeIdentifier),
       utType.conforms(to: .gif)
    {
      return true
    }

    if let suggestedName,
       (suggestedName as NSString).pathExtension.lowercased() == "gif"
    {
      return true
    }

    return mimeType?.text.lowercased() == "image/gif"
  }

  private nonisolated func isAnimatedGIF(
    at url: URL,
    suggestedName: String?,
    typeIdentifier: String?,
    mimeType: MIMEType
  ) -> Bool {
    guard isGIF(suggestedName: suggestedName, typeIdentifier: typeIdentifier, mimeType: mimeType),
          let source = CGImageSourceCreateWithURL(url as CFURL, imageSourceReadOptions())
    else {
      return false
    }

    return CGImageSourceGetCount(source) > 1
  }

  private nonisolated func preferredFileType(
    for provider: NSItemProvider,
    suggestedName: String?
  ) -> (identifier: String, fileType: MessageFileType)? {
    let identifiers = provider.registeredTypeIdentifiers
    let hasURL = provider.hasItemConformingToTypeIdentifier(UTType.url.identifier)
    let hasText = provider.hasItemConformingToTypeIdentifier(UTType.text.identifier) ||
      provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier)
    let hasSuggestedExtension: Bool = {
      guard let suggestedName else { return false }
      let ext = (suggestedName as NSString).pathExtension
      return !ext.isEmpty
    }()
    let suggestedType: UTType? = {
      guard let suggestedName else { return nil }
      let ext = (suggestedName as NSString).pathExtension
      guard !ext.isEmpty else { return nil }
      return UTType(filenameExtension: ext)
    }()
    let suggestedPrefersDocument: Bool = {
      guard hasSuggestedExtension else { return false }
      guard let suggestedType else { return true }
      return !suggestedType.conforms(to: .image) && !suggestedType.conforms(to: .movie)
    }()
    let hasFileURL = provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) ||
      identifiers.contains(UTType.fileURL.identifier)
    let pdfType = identifiers.first(where: { UTType($0)?.conforms(to: .pdf) == true })
    let movieType = identifiers.first(where: { UTType($0)?.conforms(to: .movie) == true })
    let imageType = identifiers.first(where: { UTType($0)?.conforms(to: .image) == true })

    if hasFileURL {
      if pdfType != nil || suggestedPrefersDocument {
        return (UTType.fileURL.identifier, .document)
      }
      if movieType != nil {
        return (UTType.fileURL.identifier, .video)
      }
      if imageType != nil {
        return (UTType.fileURL.identifier, .photo)
      }
      return (UTType.fileURL.identifier, .document)
    }

    if let pdfType {
      return (pdfType, .document)
    }

    if let movieType {
      return (movieType, .video)
    }

    if !suggestedPrefersDocument, let imageType {
      return (imageType, .photo)
    }

    if let dataType = identifiers.first(where: {
      guard let utType = UTType($0) else { return false }
      return utType.conforms(to: .data) &&
        !utType.conforms(to: .text) &&
        !utType.conforms(to: .url) &&
        !utType.conforms(to: .image) &&
        !utType.conforms(to: .movie)
    }) {
      if hasURL || (hasText && !hasSuggestedExtension) {
        return nil
      }
      return (dataType, .document)
    }

    if provider.hasItemConformingToTypeIdentifier(UTType.data.identifier),
       !hasURL,
       !provider.hasItemConformingToTypeIdentifier(UTType.text.identifier),
       !provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier)
    {
      return (UTType.data.identifier, .document)
    }

    return nil
  }

  private nonisolated func inferredFileType(
    for url: URL,
    typeIdentifier: String?,
    suggestedName: String?
  ) -> MessageFileType {
    if let suggestedName {
      let ext = (suggestedName as NSString).pathExtension.lowercased()
      if !ext.isEmpty {
        if let utType = UTType(filenameExtension: ext) {
          if utType.conforms(to: .pdf) { return .document }
          if utType.conforms(to: .movie) { return .video }
          if utType.conforms(to: .image) { return .photo }
          return .document
        } else {
          return .document
        }
      }
    }

    if let contentType = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType {
      if contentType.conforms(to: .pdf) { return .document }
      if contentType.conforms(to: .movie) { return .video }
      if contentType.conforms(to: .image) { return .photo }
    }

    if let typeIdentifier, let utType = UTType(typeIdentifier) {
      if utType.conforms(to: .pdf) { return .document }
      if utType.conforms(to: .movie) { return .video }
      if utType.conforms(to: .image) { return .photo }
    }

    if let utType = UTType(filenameExtension: url.pathExtension) {
      if utType.conforms(to: .pdf) { return .document }
      if utType.conforms(to: .movie) { return .video }
      if utType.conforms(to: .image) { return .photo }
    }

    return .document
  }

  private nonisolated func preferredFileExtension(for typeIdentifier: String?) -> String? {
    guard let typeIdentifier,
          let utType = UTType(typeIdentifier),
          let ext = utType.preferredFilenameExtension,
          !ext.isEmpty
    else {
      return nil
    }
    return ext
  }

  private nonisolated func sanitizedFileName(
    suggestedName: String?,
    fallbackURL: URL?,
    typeIdentifier: String?
  ) -> String {
    let suggested = safeFileNameComponent(suggestedName ?? "")
    var fileName = suggested
    if fileName.isEmpty {
      let fallback = safeFileNameComponent(fallbackURL?.lastPathComponent ?? "")
      fileName = fallback.isEmpty ? UUID().uuidString : fallback
    }

    let existingExt = (fileName as NSString).pathExtension
    if existingExt.isEmpty {
      if let fallbackURL,
         let contentType = try? fallbackURL.resourceValues(forKeys: [.contentTypeKey]).contentType,
         let preferredExt = contentType.preferredFilenameExtension,
         !preferredExt.isEmpty
      {
        fileName += ".\(preferredExt)"
      } else if let preferredExt = preferredFileExtension(for: typeIdentifier) {
        fileName += ".\(preferredExt)"
      }
    }

    return fileName
  }

  private nonisolated func safeFileNameComponent(_ value: String) -> String {
    let unsafeCharacters = CharacterSet.controlCharacters.union(
      CharacterSet(charactersIn: "/\\")
    )
    let replaced = value.unicodeScalars
      .map { unsafeCharacters.contains($0) ? "_" : String($0) }
      .joined()
      .trimmingCharacters(in: .whitespacesAndNewlines)

    guard !replaced.isEmpty, replaced != ".", replaced != ".." else {
      return ""
    }
    guard replaced.count > 180 else { return replaced }

    let name = replaced as NSString
    let fileExtension = name.pathExtension
    guard !fileExtension.isEmpty, fileExtension.count < 32 else {
      return String(replaced.prefix(180))
    }

    let stemLength = max(1, 180 - fileExtension.count - 1)
    return "\(String(name.deletingPathExtension.prefix(stemLength))).\(fileExtension)"
  }

  private nonisolated func copyToTemporaryLocation(
    from sourceURL: URL,
    suggestedName: String?,
    typeIdentifier: String?
  ) throws -> URL {
    let fileManager = FileManager.default
    let fileName = sanitizedFileName(
      suggestedName: suggestedName,
      fallbackURL: sourceURL,
      typeIdentifier: typeIdentifier
    )
    let destinationURL = fileManager.temporaryDirectory
      .appendingPathComponent("\(UUID().uuidString)_\(fileName)")
    let needsAccess = sourceURL.startAccessingSecurityScopedResource()
    defer {
      if needsAccess { sourceURL.stopAccessingSecurityScopedResource() }
    }
    do {
      try fileManager.copyItem(at: sourceURL, to: destinationURL)
      return destinationURL
    } catch {
      try? fileManager.removeItem(at: destinationURL)
      throw error
    }
  }

  private nonisolated func temporaryURL(
    suggestedName: String?,
    typeIdentifier: String?
  ) -> URL {
    let fileName = sanitizedFileName(
      suggestedName: suggestedName,
      fallbackURL: nil,
      typeIdentifier: typeIdentifier
    )
    return FileManager.default.temporaryDirectory
      .appendingPathComponent("\(UUID().uuidString)_\(fileName)")
  }

  private nonisolated func writeDataToTemporaryLocation(
    _ data: Data,
    suggestedName: String?,
    typeIdentifier: String?
  ) throws -> URL {
    let destinationURL = temporaryURL(
      suggestedName: suggestedName,
      typeIdentifier: typeIdentifier
    )
    try data.write(to: destinationURL, options: .atomic)
    return destinationURL
  }

  private nonisolated func stageFile(
    source: SharedFileSource,
    suggestedName: String?,
    typeIdentifier: String?,
    fileType: MessageFileType,
    fileSize: Int64?,
    accumulator: SharedContentAccumulator
  ) {
    let fallbackURL: URL?
    switch source {
    case let .fileURL(url):
      fallbackURL = url
    case .itemProvider:
      fallbackURL = nil
    }

    let fileName = sanitizedFileName(
      suggestedName: suggestedName,
      fallbackURL: fallbackURL,
      typeIdentifier: typeIdentifier
    )
    let mimeType = resolveMimeType(
      fileURL: fallbackURL,
      suggestedName: fileName,
      typeIdentifier: typeIdentifier
    )
    let sharedFile = SharedFile(
      source: source,
      fileName: fileName,
      typeIdentifier: typeIdentifier,
      mimeType: mimeType,
      fileType: fileType,
      fileSize: fileSize,
      isAnimatedImage: false
    )
    accumulator.addFile(sharedFile)
  }

  private nonisolated func addFile(
    from url: URL,
    suggestedName: String?,
    typeIdentifier: String?,
    fileType: MessageFileType,
    accumulator: SharedContentAccumulator
  ) {
    let fileSize = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
    stageFile(
      source: .fileURL(url),
      suggestedName: suggestedName,
      typeIdentifier: typeIdentifier,
      fileType: fileType,
      fileSize: fileSize.map { Int64($0) },
      accumulator: accumulator
    )
  }

  private nonisolated func addFile(
    from itemProvider: SendableItemProvider,
    suggestedName: String?,
    typeIdentifier: String,
    fileType: MessageFileType,
    accumulator: SharedContentAccumulator
  ) {
    stageFile(
      source: .itemProvider(itemProvider, typeIdentifier: typeIdentifier),
      suggestedName: suggestedName,
      typeIdentifier: typeIdentifier,
      fileType: fileType,
      fileSize: nil,
      accumulator: accumulator
    )
  }

  private nonisolated func handleLoadedURLItem(
    _ item: NSSecureCoding?,
    suggestedName: String?,
    accumulator: SharedContentAccumulator
  ) {
    if let url = item as? URL {
      if url.isFileURL {
        let resolvedType = inferredFileType(for: url, typeIdentifier: nil, suggestedName: suggestedName)
        addFile(
          from: url,
          suggestedName: suggestedName,
          typeIdentifier: UTType.fileURL.identifier,
          fileType: resolvedType,
          accumulator: accumulator
        )
      } else {
        accumulator.addURL(url)
      }
      return
    }

    if let string = item as? String, let url = URL(string: string) {
      if url.isFileURL {
        let resolvedType = inferredFileType(for: url, typeIdentifier: nil, suggestedName: suggestedName)
        addFile(
          from: url,
          suggestedName: suggestedName,
          typeIdentifier: UTType.fileURL.identifier,
          fileType: resolvedType,
          accumulator: accumulator
        )
      } else {
        accumulator.addURL(url)
      }
      return
    }

    if let data = item as? Data,
       let string = String(data: data, encoding: .utf8),
       let url = URL(string: string)
    {
      if url.isFileURL {
        let resolvedType = inferredFileType(for: url, typeIdentifier: nil, suggestedName: suggestedName)
        addFile(
          from: url,
          suggestedName: suggestedName,
          typeIdentifier: UTType.fileURL.identifier,
          fileType: resolvedType,
          accumulator: accumulator
        )
      } else {
        accumulator.addURL(url)
      }
      return
    }

    log.warning(tagged("Unsupported URL payload"))
  }

  private nonisolated func handleLoadedTextItem(
    _ item: NSSecureCoding?,
    accumulator: SharedContentAccumulator
  ) {
    if let text = item as? String {
      accumulator.addText(text)
      return
    }

    if let attributed = item as? NSAttributedString {
      accumulator.addText(attributed.string)
      return
    }

    if let data = item as? Data, let text = String(data: data, encoding: .utf8) {
      accumulator.addText(text)
      return
    }

    log.warning(tagged("Unsupported text payload"))
  }

  private nonisolated func shareError(code: Int, message: String) -> NSError {
    NSError(
      domain: "ShareError",
      code: code,
      userInfo: [NSLocalizedDescriptionKey: message]
    )
  }

  private nonisolated func cleanupTemporaryFiles(_ urls: [URL]) {
    var seen = Set<URL>()
    for url in urls where seen.insert(url).inserted {
      _ = try? FileManager.default.removeItem(at: url)
    }
  }

  private nonisolated func loadTemporaryFile(for file: SharedFile) async throws -> TemporarySharedFile {
    log.debug(tagged(
      "Preparing staged file source=\(sourceLogValue(for: file.source)) " +
        "type=\(file.fileType) uti=\(logValue(file.typeIdentifier)) " +
        "mime=\(file.mimeType.text) size=\(fileSizeLogValue(file.fileSize))"
    ))

    if file.fileType == .document,
       let fileSize = file.fileSize,
       fileSize > Self.maxFileSizeBytes {
      throw shareError(
        code: 3,
        message: "\(file.fileName) is too large. Maximum size is \(Self.maxFileSizeDisplay(for: Self.maxFileSizeBytes))."
      )
    }

    switch file.source {
    case let .fileURL(url):
      let tempURL = try copyToTemporaryLocation(
        from: url,
        suggestedName: file.fileName,
        typeIdentifier: file.typeIdentifier
      )
      let resolvedType = file.fileType == .document
        ? inferredFileType(for: tempURL, typeIdentifier: file.typeIdentifier, suggestedName: file.fileName)
        : file.fileType
      return TemporarySharedFile(
        url: tempURL,
        fileName: file.fileName,
        typeIdentifier: file.typeIdentifier,
        fileType: resolvedType,
        cleanupURLs: [tempURL]
      )

    case let .itemProvider(itemProvider, typeIdentifier):
      return try await loadTemporaryFile(
        from: itemProvider,
        typeIdentifier: typeIdentifier,
        stagedFile: file
      )
    }
  }

  private nonisolated func loadTemporaryFile(
    from itemProvider: SendableItemProvider,
    typeIdentifier: String,
    stagedFile: SharedFile
  ) async throws -> TemporarySharedFile {
    if typeIdentifier == UTType.fileURL.identifier {
      return try await loadItemTemporaryFile(
        from: itemProvider,
        typeIdentifier: typeIdentifier,
        stagedFile: stagedFile
      )
    }

    do {
      return try await loadFileRepresentationTemporaryFile(
        from: itemProvider,
        typeIdentifier: typeIdentifier,
        stagedFile: stagedFile
      )
    } catch {
      if stagedFile.fileType == .photo || stagedFile.fileType == .video {
        log.warning(tagged(
          "File representation unavailable for media; refusing decoded fallback " +
            "type=\(stagedFile.fileType) uti=\(typeIdentifier) error=\(error.localizedDescription)"
        ))
        throw shareError(
          code: 16,
          message: "Inline could not access the shared media file. Try saving it to Files and sharing again."
        )
      }
      log.warning(tagged(
        "File representation unavailable; falling back to item load " +
          "type=\(stagedFile.fileType) uti=\(typeIdentifier) error=\(error.localizedDescription)"
      ))
      return try await loadItemTemporaryFile(
        from: itemProvider,
        typeIdentifier: typeIdentifier,
        stagedFile: stagedFile
      )
    }
  }

  private nonisolated func loadFileRepresentationTemporaryFile(
    from itemProvider: SendableItemProvider,
    typeIdentifier: String,
    stagedFile: SharedFile
  ) async throws -> TemporarySharedFile {
    try await withCheckedThrowingContinuation { continuation in
      itemProvider.provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { [weak self] url, error in
        guard let self else {
          continuation.resume(throwing: NSError(
            domain: "ShareError",
            code: 16,
            userInfo: [NSLocalizedDescriptionKey: "Inline stopped preparing the shared file."]
          ))
          return
        }
        if let error {
          continuation.resume(throwing: error)
          return
        }
        guard let url else {
          continuation.resume(throwing: shareError(code: 16, message: "Unable to read shared file."))
          return
        }

        do {
          let tempURL = try copyToTemporaryLocation(
            from: url,
            suggestedName: stagedFile.fileName,
            typeIdentifier: typeIdentifier
          )
          let fileName = sanitizedFileName(
            suggestedName: stagedFile.fileName,
            fallbackURL: tempURL,
            typeIdentifier: typeIdentifier
          )
          let resolvedType = stagedFile.fileType == .document
            ? inferredFileType(for: tempURL, typeIdentifier: typeIdentifier, suggestedName: fileName)
            : stagedFile.fileType
          continuation.resume(returning: TemporarySharedFile(
            url: tempURL,
            fileName: fileName,
            typeIdentifier: typeIdentifier,
            fileType: resolvedType,
            cleanupURLs: [tempURL]
          ))
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }

  private nonisolated func loadItemTemporaryFile(
    from itemProvider: SendableItemProvider,
    typeIdentifier: String,
    stagedFile: SharedFile
  ) async throws -> TemporarySharedFile {
    try await withCheckedThrowingContinuation { continuation in
      let options: [AnyHashable: Any]? = stagedFile.fileType == .photo
        ? [
          NSItemProviderPreferredImageSizeKey: NSValue(
            cgSize: CGSize(
              width: Self.maxPhotoUploadDimension,
              height: Self.maxPhotoUploadDimension
            )
          ),
        ]
        : nil
      itemProvider.provider.loadItem(forTypeIdentifier: typeIdentifier, options: options) { [weak self] item, error in
        guard let self else {
          continuation.resume(throwing: NSError(
            domain: "ShareError",
            code: 16,
            userInfo: [NSLocalizedDescriptionKey: "Inline stopped preparing the shared file."]
          ))
          return
        }
        if let error {
          continuation.resume(throwing: error)
          return
        }

        do {
          let temporaryFile = try temporaryFile(
            fromLoadedItem: item,
            typeIdentifier: typeIdentifier,
            stagedFile: stagedFile
          )
          continuation.resume(returning: temporaryFile)
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }

  private nonisolated func temporaryFile(
    fromLoadedItem item: NSSecureCoding?,
    typeIdentifier: String,
    stagedFile: SharedFile
  ) throws -> TemporarySharedFile {
    if let url = item as? URL {
      guard url.isFileURL else {
        throw shareError(code: 16, message: "The shared URL is not a file.")
      }
      let tempURL = try copyToTemporaryLocation(
        from: url,
        suggestedName: stagedFile.fileName,
        typeIdentifier: typeIdentifier
      )
      let resolvedType = stagedFile.fileType == .document
        ? inferredFileType(for: tempURL, typeIdentifier: typeIdentifier, suggestedName: stagedFile.fileName)
        : stagedFile.fileType
      return TemporarySharedFile(
        url: tempURL,
        fileName: stagedFile.fileName,
        typeIdentifier: typeIdentifier,
        fileType: resolvedType,
        cleanupURLs: [tempURL]
      )
    }

    if let string = item as? String,
       let url = URL(string: string),
       url.isFileURL
    {
      return try temporaryFile(
        fromLoadedItem: url as NSURL,
        typeIdentifier: typeIdentifier,
        stagedFile: stagedFile
      )
    }

    if let data = item as? Data {
      if typeIdentifier == UTType.fileURL.identifier,
         let string = String(data: data, encoding: .utf8),
         let url = URL(string: string),
         url.isFileURL
      {
        return try temporaryFile(
          fromLoadedItem: url as NSURL,
          typeIdentifier: typeIdentifier,
          stagedFile: stagedFile
        )
      }

      if stagedFile.fileType == .photo || stagedFile.fileType == .video {
        throw shareError(
          code: 16,
          message: "Inline could not access the shared media as a file."
        )
      }

      let tempURL = try writeDataToTemporaryLocation(
        data,
        suggestedName: stagedFile.fileName,
        typeIdentifier: typeIdentifier
      )
      return TemporarySharedFile(
        url: tempURL,
        fileName: stagedFile.fileName,
        typeIdentifier: typeIdentifier,
        fileType: stagedFile.fileType,
        cleanupURLs: [tempURL]
      )
    }

    throw shareError(code: 16, message: "Unable to read the shared file.")
  }

  private nonisolated func prepareFileForUpload(_ file: SharedFile) async throws -> PreparedSharedFile {
    log.info(tagged(
      "Preparing attachment type=\(file.fileType) source=\(sourceLogValue(for: file.source)) " +
        "uti=\(logValue(file.typeIdentifier))"
    ))
    let temporaryFile = try await loadTemporaryFile(for: file)
    do {
      let preparedFile = try prepareTemporaryFileForUpload(temporaryFile)
      log.info(tagged(
        "Prepared attachment type=\(preparedFile.fileType) " +
          "mime=\(preparedFile.mimeType.text) size=\(preparedFile.fileSize)"
      ))
      return preparedFile
    } catch {
      cleanupTemporaryFiles(temporaryFile.cleanupURLs)
      throw error
    }
  }

  private nonisolated func prepareTemporaryFileForUpload(_ file: TemporarySharedFile) throws -> PreparedSharedFile {
    let fileName = sanitizedFileName(
      suggestedName: file.fileName,
      fallbackURL: file.url,
      typeIdentifier: file.typeIdentifier
    )
    let mimeType = resolveMimeType(
      fileURL: file.url,
      suggestedName: fileName,
      typeIdentifier: file.typeIdentifier
    )
    var resolvedFileType = file.fileType == .document
      ? inferredFileType(for: file.url, typeIdentifier: file.typeIdentifier, suggestedName: fileName)
      : file.fileType
    var isAnimatedImage = false

    if resolvedFileType == .photo,
       isAnimatedGIF(
         at: file.url,
         suggestedName: fileName,
         typeIdentifier: file.typeIdentifier,
         mimeType: mimeType
       )
    {
      resolvedFileType = .video
      isAnimatedImage = true
    }

    if resolvedFileType == .photo &&
        (shouldTranscodePhotoToJpeg(
          suggestedName: fileName,
          typeIdentifier: file.typeIdentifier,
          mimeType: mimeType
        ) || !isSupportedPhotoMimeType(mimeType))
    {
      if let photoFile = try downsampledPhotoFile(
        from: file.url,
        fileName: jpegFileName(from: fileName),
        cleanupURLs: file.cleanupURLs
      ) {
        return photoFile
      }

      if shouldTranscodePhotoToJpeg(
        suggestedName: fileName,
        typeIdentifier: file.typeIdentifier,
        mimeType: mimeType
      ) {
        log.warning(tagged("Failed to transcode HEIC photo; falling back to document"))
      } else {
        log.warning(tagged("Unsupported photo MIME type; falling back to document (\(mimeType.text))"))
      }
      resolvedFileType = .document
    }

    if resolvedFileType == .photo {
      if shouldSendPhotoAsDocument(at: file.url) {
        resolvedFileType = .document
        log.warning(tagged("Photo aspect ratio is too extreme; sending as document"))
      } else if shouldOptimizePhotoUpload(mimeType: mimeType),
                let optimized = try optimizedPhotoUploadFile(
                  from: file.url,
                  suggestedName: fileName,
                  cleanupURLs: file.cleanupURLs
                ) {
        return optimized
      }
    }

    let size = fileSize(for: file.url) ?? 0
    return PreparedSharedFile(
      url: file.url,
      fileName: fileName,
      mimeType: mimeType,
      fileType: resolvedFileType,
      fileSize: size,
      isAnimatedImage: isAnimatedImage,
      videoMetadata: nil,
      cleanupURLs: file.cleanupURLs
    )
  }

  private nonisolated func buildVideoMetadata(from url: URL) async throws -> ApiClient.VideoUploadMetadata {
    let asset = AVURLAsset(url: url)
    let tracks = try await asset.loadTracks(withMediaType: .video)
    guard let track = tracks.first else {
      throw NSError(
        domain: "ShareError",
        code: 6,
        userInfo: [NSLocalizedDescriptionKey: "Unable to read video track."]
      )
    }

    let naturalSize = try await track.load(.naturalSize)
    let transform = try await track.load(.preferredTransform)
    let transformedSize = naturalSize.applying(transform)
    let width = Int(abs(transformedSize.width.rounded()))
    let height = Int(abs(transformedSize.height.rounded()))

    let durationTime = try await asset.load(.duration)
    let seconds = CMTimeGetSeconds(durationTime)
    let duration = seconds.isFinite ? Int(seconds.rounded()) : 0
    let audioTracks = try? await asset.loadTracks(withMediaType: .audio)

    guard width > 0, height > 0, duration > 0 else {
      throw NSError(
        domain: "ShareError",
        code: 7,
        userInfo: [NSLocalizedDescriptionKey: "Missing video metadata."]
      )
    }

    let thumbnailPayload = try? generateVideoThumbnail(from: asset, durationSeconds: seconds)

    return ApiClient.VideoUploadMetadata(
      width: width,
      height: height,
      duration: duration,
      thumbnail: thumbnailPayload?.data,
      thumbnailMimeType: thumbnailPayload?.mimeType,
      hasAudio: audioTracks?.isEmpty == false
    )
  }

  private nonisolated func prepareVideoForUpload(
    _ file: PreparedSharedFile
  ) async throws -> PreparedSharedFile {
    if file.isAnimatedImage {
      return try await prepareAnimatedImageVideoForUpload(file)
    }

    let needsMp4Transcode = file.url.pathExtension.lowercased() != "mp4"
    let options = VideoCompressionOptions.uploadDefault(forceTranscode: needsMp4Transcode)
    let originalFileSize = file.fileSize
    log.debug(tagged(
      "Preparing video upload transcodeRequired=\(needsMp4Transcode) size=\(originalFileSize)"
    ))

    do {
      let result = try await VideoCompressor.shared.compressVideo(at: file.url, options: options)
      let baseName = (file.fileName as NSString).deletingPathExtension
      let resolvedName = baseName.isEmpty ? "video.mp4" : "\(baseName).mp4"
      let mimeType = MIMEType(text: FileHelpers.getMimeType(for: result.url))
      let preparedFile = PreparedSharedFile(
        url: result.url,
        fileName: resolvedName,
        mimeType: mimeType,
        fileType: .video,
        fileSize: result.fileSize,
        isAnimatedImage: false,
        videoMetadata: nil,
        cleanupURLs: file.cleanupURLs + [result.url]
      )
      log.debug(tagged("Video compression completed size=\(result.fileSize)"))
      return preparedFile
    } catch VideoCompressionError.compressionNotNeeded, VideoCompressionError.compressionNotEffective {
      if needsMp4Transcode {
        throw NSError(
          domain: "ShareError",
          code: 11,
          userInfo: [NSLocalizedDescriptionKey: "Failed to convert video to MP4."]
        )
      }
      log.debug(tagged("Video compression skipped; using original MP4"))
      return PreparedSharedFile(
        url: file.url,
        fileName: file.fileName,
        mimeType: file.mimeType,
        fileType: .video,
        fileSize: originalFileSize,
        isAnimatedImage: false,
        videoMetadata: file.videoMetadata,
        cleanupURLs: file.cleanupURLs
      )
    } catch {
      if needsMp4Transcode {
        throw NSError(
          domain: "ShareError",
          code: 12,
          userInfo: [NSLocalizedDescriptionKey: "Failed to compress video for upload."]
        )
      }
      log.debug(tagged("Video compression failed; using original MP4 error=\(error.localizedDescription)"))
      return PreparedSharedFile(
        url: file.url,
        fileName: file.fileName,
        mimeType: file.mimeType,
        fileType: .video,
        fileSize: originalFileSize,
        isAnimatedImage: false,
        videoMetadata: file.videoMetadata,
        cleanupURLs: file.cleanupURLs
      )
    }
  }

  private nonisolated func prepareAnimatedImageVideoForUpload(
    _ file: PreparedSharedFile
  ) async throws -> PreparedSharedFile {
    let conversion = try await AnimatedImageVideoConverter.convertGIF(at: file.url)
    let baseName = (file.fileName as NSString).deletingPathExtension
    let resolvedName = baseName.isEmpty ? "animation.mp4" : "\(baseName).mp4"
    let thumbnailData = conversion.thumbnail?.cgImage.flatMap {
      jpegData(from: $0, compressionQuality: 0.7)
    }
    let metadata = ApiClient.VideoUploadMetadata(
      width: conversion.width,
      height: conversion.height,
      duration: conversion.duration,
      thumbnail: thumbnailData,
      thumbnailMimeType: thumbnailData == nil ? nil : MIMEType(text: "image/jpeg"),
      isAnimated: true,
      hasAudio: false
    )
    return PreparedSharedFile(
      url: conversion.url,
      fileName: resolvedName,
      mimeType: MIMEType(text: "video/mp4"),
      fileType: .video,
      fileSize: conversion.fileSize,
      isAnimatedImage: false,
      videoMetadata: metadata,
      cleanupURLs: file.cleanupURLs + [conversion.url]
    )
  }

  private nonisolated func fileSize(for url: URL) -> Int64? {
    guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
      return nil
    }
    return Int64(size)
  }

  private nonisolated func generateVideoThumbnail(
    from asset: AVAsset,
    durationSeconds: Double
  ) throws -> (data: Data, mimeType: MIMEType)? {
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = CGSize(width: 480, height: 480)

    let captureTime = CMTime(seconds: max(0, min(durationSeconds * 0.1, 1.0)), preferredTimescale: 600)
    let cgImage = try generator.copyCGImage(at: captureTime, actualTime: nil)
    guard let jpegData = jpegData(from: cgImage) else {
      return nil
    }

    return (jpegData, MIMEType(text: "image/jpeg"))
  }

  private nonisolated func inputPeer(for chat: SharedChat) throws -> InputPeer {
    if let peerUserId = chat.peerUserId {
      return Peer.user(id: peerUserId).toInputPeer()
    }
    if let peerThreadId = chat.peerThreadId {
      return Peer.thread(id: peerThreadId).toInputPeer()
    }
    throw NSError(
      domain: "ShareError",
      code: 8,
      userInfo: [NSLocalizedDescriptionKey: "Unable to determine chat destination."]
    )
  }

  private nonisolated func inputMedia(
    for fileType: MessageFileType,
    uploadResult: InlineKit.UploadFileResult
  ) throws -> InputMedia {
    switch fileType {
      case .photo:
        guard let photoId = uploadResult.photoId else {
          throw NSError(
            domain: "ShareError",
            code: 9,
            userInfo: [NSLocalizedDescriptionKey: "Photo upload did not return an ID."]
          )
        }
        return .fromPhotoId(photoId)
      case .video:
        guard let videoId = uploadResult.videoId else {
          throw NSError(
            domain: "ShareError",
            code: 10,
            userInfo: [NSLocalizedDescriptionKey: "Video upload did not return an ID."]
          )
        }
        return .fromVideoId(videoId)
      case .document:
        guard let documentId = uploadResult.documentId else {
          throw NSError(
            domain: "ShareError",
            code: 11,
            userInfo: [NSLocalizedDescriptionKey: "Document upload did not return an ID."]
          )
        }
        return .fromDocumentId(documentId)
      case .voice:
        throw NSError(
          domain: "ShareError",
          code: 12,
          userInfo: [NSLocalizedDescriptionKey: "Voice messages are not supported from the share extension."]
        )
    }
  }

  @MainActor
  private func startRealtimeIfNeeded() async {
    guard !hasStartedRealtime else { return }
    hasStartedRealtime = true
    if Auth.shared.getToken() == nil {
      await Auth.shared.refreshFromStorage()
    }
    guard Auth.shared.getToken() != nil else {
      log.warning(tagged("Realtime start skipped (missing auth token)"))
      hasStartedRealtime = false
      return
    }
    await Realtime.shared.start()
  }

  private nonisolated func waitForRealtimeConnected(maxSeconds: TimeInterval) async -> Bool {
    let start = Date()
    var lastState: RealtimeAPIState?

    while Date().timeIntervalSince(start) < maxSeconds {
      let state = await MainActor.run { Realtime.shared.apiState }
      if state != lastState {
        log.debug(tagged("Realtime state: \(state)"))
        lastState = state
      }

      if state == .connected || state == .updating {
        return true
      }

      try? await Task.sleep(for: .milliseconds(150))
    }

    log.warning(tagged("Realtime still connecting after \(maxSeconds)s"))
    return false
  }

  private nonisolated func invokeSendMessage(
    _ input: SendMessageInput,
    timeoutSeconds: TimeInterval
  ) async throws -> RpcResult.OneOf_Result? {
    try await withCheckedThrowingContinuation { continuation in
      let gate = SendMessageInvocationGate(continuation: continuation)

      // Realtime V1 stores a checked continuation and does not currently react to task
      // cancellation. Use unstructured racers so the extension deadline can still resolve.
      // The caller retries with the same random ID, so a late first invocation is deduplicated.
      Task {
        do {
          let result = try await Realtime.shared.invoke(
            .sendMessage,
            input: .sendMessage(input),
            discardIfNotConnected: false
          )
          gate.resume(with: .success(result))
        } catch {
          gate.resume(with: .failure(error))
        }
      }

      Task {
        do {
          try await Task.sleep(for: .seconds(timeoutSeconds))
        } catch {
          return
        }

        gate.resume(with: .failure(NSError(
          domain: "ShareError",
          code: 15,
          userInfo: [NSLocalizedDescriptionKey: "Inline couldn't reach the server."]
        )))
      }
    }
  }

  private nonisolated func sendMessageToChat(
    _ selectedChat: SharedChat,
    text: String?,
    media: InputMedia?
  ) async throws {
    if Auth.shared.getToken() == nil {
      await Auth.shared.refreshFromStorage()
    }

    guard Auth.shared.getToken() != nil else {
      throw NSError(
        domain: "ShareError",
        code: 13,
        userInfo: [NSLocalizedDescriptionKey: "Inline needs to be opened before you can share."]
      )
    }

    await startRealtimeIfNeeded()
    let didConnect = await waitForRealtimeConnected(maxSeconds: realtimeConnectWarmupSeconds)
    if !didConnect {
      log.warning(tagged("Realtime not connected yet; send will wait on queue"))
    }

    let inputPeer = try inputPeer(for: selectedChat)
    let randomId = Int64.random(in: 0 ... Int64.max)
    let sendDate = Int64(Date().timeIntervalSince1970.rounded())

    let input: SendMessageInput = .with {
      $0.peerID = inputPeer
      $0.randomID = randomId
      $0.temporarySendDate = sendDate
      if let text { $0.message = text }
      if let media { $0.media = media }
    }

    // Use Realtime V1 for share extension reliability until V2 direct RPC is stable here.
    for attempt in 0 ..< 2 {
      do {
        log.debug(tagged("Send attempt \(attempt + 1)"))
        let result = try await invokeSendMessage(input, timeoutSeconds: sendTimeoutSeconds)
        guard case .sendMessage = result else {
          throw NSError(
            domain: "ShareError",
            code: 12,
            userInfo: [NSLocalizedDescriptionKey: "Failed to send message."]
          )
        }
        return
      } catch let error as RealtimeAPIError {
        if case .notConnected = error, attempt == 0 {
          log.warning(tagged("Realtime not connected during send, retrying"))
          await startRealtimeIfNeeded()
          _ = await waitForRealtimeConnected(maxSeconds: realtimeConnectRetrySeconds)
          continue
        }
        throw error
      } catch let error as NSError where error.domain == "ShareError" && error.code == 15 && attempt == 0 {
        log.warning(tagged("Realtime send timed out, retrying"))
        await startRealtimeIfNeeded()
        _ = await waitForRealtimeConnected(maxSeconds: realtimeConnectRetrySeconds)
        continue
      }
    }

    throw NSError(
      domain: "ShareError",
      code: 14,
      userInfo: [NSLocalizedDescriptionKey: "Inline couldn't reach the server."]
    )
  }

  private nonisolated func combinedMessageText(
    caption: String,
    content: SharedContent
  ) -> String? {
    var parts: [String] = []
    let trimmedCaption = caption.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmedCaption.isEmpty {
      parts.append(trimmedCaption)
    }
    if let contentText = content.combinedText {
      parts.append(contentText)
    }
    if !content.urls.isEmpty {
      let urlText = content.urls.map(\.absoluteString).joined(separator: "\n")
      if !urlText.isEmpty {
        parts.append(urlText)
      }
    }
    guard !parts.isEmpty else { return nil }
    return parts.joined(separator: "\n\n")
  }

  struct ErrorState: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let suggestion: String?
    let retryable: Bool

    init(title: String, message: String, suggestion: String?, retryable: Bool = false) {
      self.title = title
      self.message = message
      self.suggestion = suggestion
      self.retryable = retryable
    }
  }

  private struct ErrorPresentation {
    let title: String
    let message: String
    let suggestion: String?
    let retryable: Bool
  }

  struct ShareProgressState: Equatable {
    var title: String
    var detail: String?
    var fractionCompleted: Double?

    static let idle = ShareProgressState(title: "", detail: nil, fractionCompleted: nil)
  }

  private nonisolated func progressDetail(
    for fileType: MessageFileType,
    itemNumber: Int,
    totalItems: Int
  ) -> String {
    let itemName: String = switch fileType {
    case .photo: "Photo"
    case .video: "Video"
    case .document: "File"
    case .voice: "Audio"
    }
    return totalItems > 1 ? "\(itemName) \(itemNumber) of \(totalItems)" : itemName
  }

  func loadSharedData() {
    sharedData = BridgeManager.shared.loadSharedData()

    if sharedData == nil {
      log.warning(tagged("No shared data available"))
      errorState = ErrorState(
        title: "No Chats Available",
        message: "Unable to load your chats for sharing.",
        suggestion: "Please open the main Inline app first, then try sharing again."
      )
    } else {
      log.info(tagged("Shared data loaded successfully"))
    }
  }

  func finishSession() async {
    guard hasStartedRealtime else { return }
    hasStartedRealtime = false
    await Realtime.shared.suspendForSessionEnd()
  }

  func loadSharedContent(from extensionItems: [NSExtensionItem]) {
    log.info(tagged("Loading shared content (\(extensionItems.count) extension items)"))
    isLoadingContent = true
    errorState = nil
    sharedContent = nil
    contentWarnings = []
    sendProgress = ShareProgressState(title: "Preparing", detail: "Reading shared content", fractionCompleted: nil)
    let group = DispatchGroup()
    let accumulator = SharedContentAccumulator(
      maxMedia: Self.maxMedia,
      maxUrls: Self.maxUrls
    )
    var totalMediaAttachments = 0
    var totalUrlAttachments = 0
    var totalTextAttachments = 0
    var unsupportedAttachmentCount = 0

    for extensionItem in extensionItems {
      if let attributedText = extensionItem.attributedContentText?.string {
        accumulator.addText(attributedText)
        totalTextAttachments += 1
      }
      guard let attachments = extensionItem.attachments else { continue }

      for attachment in attachments {
        let suggestedName = attachment.suggestedName
        let itemProvider = SendableItemProvider(provider: attachment)
        if let fileTypeInfo = preferredFileType(
          for: attachment,
          suggestedName: suggestedName
        ) {
          totalMediaAttachments += 1
          let typeIdentifier = fileTypeInfo.identifier
          let fileType = fileTypeInfo.fileType
          addFile(
            from: itemProvider,
            suggestedName: suggestedName,
            typeIdentifier: typeIdentifier,
            fileType: fileType,
            accumulator: accumulator
          )
          continue
        }

        if attachment.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
          totalUrlAttachments += 1
          group.enter()
          attachment.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { [weak self] item, error in
            defer { group.leave() }
            guard let self else { return }
            if let error {
              self.log.error(self.tagged("Failed to load URL item"), error: error)
            }
            self.handleLoadedURLItem(
              item,
              suggestedName: suggestedName,
              accumulator: accumulator
            )
          }
          continue
        }

        if attachment.hasItemConformingToTypeIdentifier(UTType.text.identifier) ||
            attachment.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
          totalTextAttachments += 1
          let typeIdentifier = attachment.hasItemConformingToTypeIdentifier(UTType.text.identifier)
            ? UTType.text.identifier
            : UTType.plainText.identifier
          group.enter()
          attachment.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { [weak self] item, error in
            defer { group.leave() }
            guard let self else { return }
            if let error {
              self.log.error(self.tagged("Failed to load text item"), error: error)
            }
            self.handleLoadedTextItem(item, accumulator: accumulator)
          }
          continue
        }

        unsupportedAttachmentCount += 1
        log.warning(tagged("Unsupported share attachment types: \(attachment.registeredTypeIdentifiers)"))
      }
    }

    // Wait for all items to load and then process the results
    group.notify(queue: .main) { [weak self] in
      guard let self else { return }
      let content = accumulator.finalize()
      self.isLoadingContent = false
      self.sendProgress = .idle
      if content.totalItemCount > 0 {
        self.sharedContent = content
      } else {
        self.sharedContent = nil
      }

      self.log.info(self.tagged(
        "Loaded content: \(content.photoCount) photos, \(content.videoCount) videos, " +
        "\(content.documentCount) documents, \(content.urls.count) urls, text=\(content.hasText)"
      ))

      if totalMediaAttachments > Self.maxMedia {
        self.log.warning(self.tagged("Limited to \(Self.maxMedia) media items out of \(totalMediaAttachments) provided"))
        self.contentWarnings.append("Only the first \(Self.maxMedia) media items will be sent.")
      }
      if totalUrlAttachments > Self.maxUrls {
        self.log.warning(self.tagged("Limited to \(Self.maxUrls) URLs out of \(totalUrlAttachments) provided"))
        self.contentWarnings.append("Only the first \(Self.maxUrls) links will be sent.")
      }
      if unsupportedAttachmentCount > 0 {
        self.contentWarnings.append("\(unsupportedAttachmentCount) unsupported item\(unsupportedAttachmentCount == 1 ? "" : "s") skipped.")
      }
      if totalTextAttachments == 0, content.totalItemCount == 0 {
        self.log.warning(self.tagged("No usable share content found"))
      }
    }
  }

  func sendMessage(caption: String, selectedChat: SharedChat, completion: @escaping () -> Void) {
    sendMessage(caption: caption, selectedChats: [selectedChat], completion: completion)
  }

  func sendMessage(caption: String, selectedChats: [SharedChat], completion: @escaping () -> Void) {
    guard !isSending else { return }
    guard let sharedContent else {
      log.error(tagged("No content to share"))
      errorState = ErrorState(
        title: "No Content",
        message: "No content was selected to share.",
        suggestion: "Please select something to share."
      )
      return
    }

    let destinationChats = uniqueSendableChats(from: selectedChats)
    guard !destinationChats.isEmpty else {
      errorState = ErrorState(
        title: "No Destination",
        message: "Choose at least one chat before sending.",
        suggestion: nil
      )
      return
    }

    if Auth.shared.getToken() == nil {
      log.warning(tagged("Missing auth token for share; attempting refresh"))
    }

    isSending = true
    isSent = false
    uploadProgress = 0
    sendProgress = ShareProgressState(
      title: "Preparing",
      detail: destinationChats.count == 1 ? "Preparing share" : "Preparing share for \(destinationChats.count) chats",
      fractionCompleted: nil
    )

    let messageText = combinedMessageText(caption: caption, content: sharedContent)
    let content = sharedContent

    Task.detached(priority: .userInitiated) { [weak self] in
      guard let self else { return }
      var didSendAnyMessage = false
      do {
        let apiClient = ApiClient.shared
        let sendStart = Date()
        let totalMediaItems = content.mediaCount
        let totalUploadItems = max(totalMediaItems, 1)
        let totalSendOperations = max(totalMediaItems, 1) * destinationChats.count
        var uploadedItems = 0
        var sentOperations = 0
        var didAttachTextToMedia = false

        if !content.files.isEmpty {
          self.log.info(self.tagged("Sending \(content.files.count) attachments to \(destinationChats.count) destinations"))
        }

        for stagedFile in content.files {
          let preparingItemNumber = uploadedItems + 1
          let preparingTitle: String = switch stagedFile.fileType {
          case .photo: "Preparing photo"
          case .video: "Preparing video"
          case .document: "Preparing file"
          case .voice: "Preparing audio"
          }
          await MainActor.run {
            self.sendProgress = ShareProgressState(
              title: preparingTitle,
              detail: self.progressDetail(
                for: stagedFile.fileType,
                itemNumber: preparingItemNumber,
                totalItems: totalUploadItems
              ),
              fractionCompleted: self.uploadProgress
            )
          }

          var preparedFile = try await prepareFileForUpload(stagedFile)
          var cleanupURLs = preparedFile.cleanupURLs
          defer { cleanupTemporaryFiles(cleanupURLs) }
          if preparedFile.fileType == .video {
            preparedFile = try await prepareVideoForUpload(preparedFile)
            cleanupURLs = preparedFile.cleanupURLs
          }

          self.log.info(self.tagged(
            "Uploading attachment type=\(preparedFile.fileType) " +
              "mime=\(preparedFile.mimeType.text) size=\(preparedFile.fileSize)"
          ))
          let maxAllowedSize = preparedFile.fileType == .video ? Self.maxVideoFileSizeBytes : Self.maxFileSizeBytes
          guard preparedFile.fileSize <= maxAllowedSize else {
            throw NSError(
              domain: "ShareError",
              code: 3,
              userInfo: [
                NSLocalizedDescriptionKey:
                  "\(preparedFile.fileName) is too large. Maximum size is \(Self.maxFileSizeDisplay(for: maxAllowedSize))."
              ]
            )
          }

          let uploadResult: InlineKit.UploadFileResult
          let itemIndex = uploadedItems
          let uploadDetail = progressDetail(
            for: preparedFile.fileType,
            itemNumber: itemIndex + 1,
            totalItems: totalUploadItems
          )
          let progressHandler: @Sendable (ApiClient.UploadTransferProgress) -> Void = { [weak self] progress in
            let uploadFraction = (Double(itemIndex) + progress.fractionCompleted) / Double(totalUploadItems)
            let overallFraction = min(0.72, uploadFraction * 0.72)
            Task { @MainActor in
              self?.uploadProgress = overallFraction
              self?.sendProgress = ShareProgressState(
                title: "Uploading \(itemIndex + 1) of \(totalUploadItems)",
                detail: uploadDetail,
                fractionCompleted: overallFraction
              )
            }
          }
          switch preparedFile.fileType {
          case .photo:
            uploadResult = try await apiClient.uploadFile(
              type: .photo,
              fileURL: preparedFile.url,
              filename: preparedFile.fileName,
              mimeType: preparedFile.mimeType,
              progress: progressHandler
            )
          case .document:
            uploadResult = try await apiClient.uploadFile(
              type: .document,
              fileURL: preparedFile.url,
              filename: preparedFile.fileName,
              mimeType: preparedFile.mimeType,
              progress: progressHandler
            )
          case .video:
            let videoMetadata: ApiClient.VideoUploadMetadata
            if let preparedMetadata = preparedFile.videoMetadata {
              videoMetadata = preparedMetadata
            } else {
              videoMetadata = try await buildVideoMetadata(from: preparedFile.url)
            }
            uploadResult = try await apiClient.uploadFile(
              type: .video,
              fileURL: preparedFile.url,
              filename: preparedFile.fileName,
              mimeType: preparedFile.mimeType,
              videoMetadata: videoMetadata,
              progress: progressHandler
            )
          case .voice:
            throw NSError(
              domain: "ShareError",
              code: 13,
              userInfo: [
                NSLocalizedDescriptionKey: "Voice messages are not supported from the share extension."
              ]
            )
          }

          self.log.info(self.tagged(
            "Upload completed type=\(preparedFile.fileType) result=\(self.uploadResultLogValue(uploadResult))"
          ))
          uploadedItems += 1
          let uploadCompletionFraction = Double(uploadedItems) / Double(totalUploadItems) * 0.72
          await MainActor.run {
            self.uploadProgress = max(self.uploadProgress, uploadCompletionFraction)
          }

          let fileText = (!didAttachTextToMedia && messageText != nil) ? messageText : nil
          let media = try inputMedia(for: preparedFile.fileType, uploadResult: uploadResult)
          for chat in destinationChats {
            let destinationName = await self.displayName(for: chat)
            let operationNumber = sentOperations + 1
            let sendFraction = 0.72 + (Double(sentOperations) / Double(totalSendOperations) * 0.22)
            await MainActor.run {
              self.uploadProgress = max(self.uploadProgress, sendFraction)
              self.sendProgress = ShareProgressState(
                title: "Sending \(operationNumber) of \(totalSendOperations)",
                detail: destinationName,
                fractionCompleted: sendFraction
              )
            }
            try await sendMessageToChat(
              chat,
              text: fileText,
              media: media
            )
            didSendAnyMessage = true
            sentOperations += 1
          }

          didAttachTextToMedia = didAttachTextToMedia || (messageText != nil)
          let sendCompletionFraction = 0.72 + (Double(sentOperations) / Double(totalSendOperations) * 0.22)
          await MainActor.run {
            self.uploadProgress = max(self.uploadProgress, sendCompletionFraction)
          }
        }

        if totalMediaItems == 0, let messageText {
          for chat in destinationChats {
            let destinationName = await self.displayName(for: chat)
            let operationNumber = sentOperations + 1
            let sendFraction = 0.1 + (Double(sentOperations) / Double(totalSendOperations) * 0.84)
            await MainActor.run {
              self.uploadProgress = sendFraction
              self.sendProgress = ShareProgressState(
                title: "Sending \(operationNumber) of \(totalSendOperations)",
                detail: destinationName,
                fractionCompleted: sendFraction
              )
            }
            try await sendMessageToChat(chat, text: messageText, media: nil)
            didSendAnyMessage = true
            sentOperations += 1
          }
        } else if totalMediaItems > 0, messageText == nil {
          await MainActor.run {
            self.uploadProgress = max(self.uploadProgress, 0.94)
          }
        }

        if destinationChats.count == 1, let chat = destinationChats.first {
          do {
            let users = await MainActor.run {
              self.sharedData?.shareExtensionData.users ?? []
            }
            try await InlineMessageIntentDonation.donate(
              chat.intentDonationRequest(users: users, direction: .outgoing)
            )
          } catch {
            log.warning(tagged("Failed to donate send-message intent: \(error.localizedDescription)"))
          }
        }

        await MainActor.run {
          self.isSending = false
          self.isSent = true
          self.uploadProgress = 1.0
          self.sendProgress = ShareProgressState(
            title: "Sent",
            detail: destinationChats.count == 1 ? self.displayName(for: destinationChats[0]) : "\(destinationChats.count) chats",
            fractionCompleted: 1
          )
          let feedback = UINotificationFeedbackGenerator()
          feedback.prepare()
          feedback.notificationOccurred(.success)

          // Let the success animation land before dismissing the extension.
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) {
            completion()
          }
        }
        self.log.info(self.tagged("Share completed in \(Date().timeIntervalSince(sendStart))s"))
      } catch {
        self.log.error(self.tagged("Failed to share content"), error: error)
        let didPartiallySend = didSendAnyMessage
        await self.finishSession()

        await MainActor.run {
          let errorMessage = self.errorPresentation(for: error, didPartiallySend: didPartiallySend)

          self.errorState = ErrorState(
            title: errorMessage.title,
            message: errorMessage.message,
            suggestion: errorMessage.suggestion,
            retryable: errorMessage.retryable
          )
          self.isSending = false
          self.sendProgress = .idle
        }
      }
    }
  }

  private func uniqueSendableChats(from chats: [SharedChat]) -> [SharedChat] {
    var seen = Set<Int64>()
    var result: [SharedChat] = []
    for chat in chats {
      guard chat.peerUserId != nil || chat.peerThreadId != nil else { continue }
      guard seen.insert(chat.id).inserted else { continue }
      result.append(chat)
    }
    return result
  }

  private func errorPresentation(
    for error: Error,
    didPartiallySend: Bool
  ) -> ErrorPresentation {
    if didPartiallySend {
      return ErrorPresentation(
        title: "Share Partially Sent",
        message: "Some messages may have already been sent before the failure.",
        suggestion: "Open Inline to verify the chat before trying again.",
        retryable: false
      )
    }

    if let apiError = error as? APIError {
      switch apiError {
      case .networkError:
        return ErrorPresentation(
          title: "Connection Error",
          message: "Unable to connect to the server.",
          suggestion: "Check your internet connection and try again.",
          retryable: true
        )
      case .rateLimited:
        return ErrorPresentation(
          title: "Rate Limited",
          message: "Too many requests. Please wait a moment.",
          suggestion: "Try again in a few seconds.",
          retryable: true
        )
      case let .httpError(statusCode):
        if statusCode == 401 || statusCode == 403 {
          return ErrorPresentation(
            title: "Sign In Required",
            message: "Your session has expired.",
            suggestion: "Open the Inline app and try again.",
            retryable: false
          )
        }
        return ErrorPresentation(
          title: "Server Error",
          message: "Server returned error code \(statusCode).",
          suggestion: "Please try again later.",
          retryable: true
        )
      case let .error(error, _, description):
        return ErrorPresentation(
          title: "Share Failed",
          message: description ?? error,
          suggestion: "Please try again.",
          retryable: true
        )
      default:
        return ErrorPresentation(
          title: "Share Failed",
          message: "Could not share the content.",
          suggestion: "Please check your connection and try again.",
          retryable: true
        )
      }
    }

    if let realtimeError = error as? RealtimeAPIError {
      switch realtimeError {
      case .notAuthorized:
        return ErrorPresentation(
          title: "Sign In Required",
          message: "Your session has expired.",
          suggestion: "Open the Inline app and try again.",
          retryable: false
        )
      case .notConnected:
        return ErrorPresentation(
          title: "Connection Error",
          message: "Inline couldn't reach the server.",
          suggestion: "Check your internet connection and try again.",
          retryable: true
        )
      case let .rpcError(_, message, _):
        return ErrorPresentation(
          title: "Share Failed",
          message: message ?? "The server rejected the message.",
          suggestion: "Please try again.",
          retryable: true
        )
      default:
        return ErrorPresentation(
          title: "Share Failed",
          message: "Could not share the content.",
          suggestion: "Please try again.",
          retryable: true
        )
      }
    }

    let nsError = error as NSError
    if nsError.domain == "ShareError" {
      switch nsError.code {
      case 3:
        return ErrorPresentation(
          title: "File Too Large",
          message: nsError.localizedDescription,
          suggestion: "Choose a smaller file and try again.",
          retryable: false
        )
      case 13:
        return ErrorPresentation(
          title: "Sign In Required",
          message: nsError.localizedDescription,
          suggestion: "Open the Inline app and try again.",
          retryable: false
        )
      case 14:
        return ErrorPresentation(
          title: "Connection Error",
          message: nsError.localizedDescription,
          suggestion: "Check your internet connection and try again.",
          retryable: true
        )
      case 15:
        return ErrorPresentation(
          title: "Delivery Uncertain",
          message: "Inline couldn't confirm whether the message was sent.",
          suggestion: "Open Inline to verify the chat before trying again.",
          retryable: false
        )
      default:
        return ErrorPresentation(
          title: "Share Failed",
          message: nsError.localizedDescription,
          suggestion: "Please try again.",
          retryable: true
        )
      }
    }

    return ErrorPresentation(
      title: "Share Failed",
      message: "An unexpected error occurred.",
      suggestion: "Please try again.",
      retryable: true
    )
  }

  private func displayName(for chat: SharedChat) -> String {
    displayName(for: chat, users: sharedData?.shareExtensionData.users ?? [])
  }

  private nonisolated func displayName(for chat: SharedChat, users: [SharedUser]) -> String {
    let trimmedTitle = chat.title.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmedTitle.isEmpty { return trimmedTitle }
    if let peerUserId = chat.peerUserId,
       let user = users.first(where: { $0.id == peerUserId }) {
      if let displayName = user.displayName?.trimmingCharacters(in: .whitespacesAndNewlines),
         !displayName.isEmpty {
        return displayName
      }
      let fullName = [user.firstName, user.lastName]
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .joined(separator: " ")
      if !fullName.isEmpty { return fullName }
      if let username = user.username?.trimmingCharacters(in: .whitespacesAndNewlines),
         !username.isEmpty {
        return username
      }
      if let email = user.email?.trimmingCharacters(in: .whitespacesAndNewlines),
         !email.isEmpty {
        return email
      }
    }
    return "Chat"
  }
}
