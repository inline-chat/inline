import Auth
import AVFoundation
import Foundation
import InlineKit
import InlineProtocol
import Logger
import MultipartFormDataKit
import SwiftUI
import UniformTypeIdentifiers

/// Represents a file that was shared through the extension.
struct SharedFile: Identifiable {
  let id = UUID()
  let url: URL
  let fileName: String
  let mimeType: MIMEType
  let fileType: MessageFileType
  let fileSize: Int64?
}

/// Aggregated shared content from the extension.
struct SharedContent {
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
}

private final class SharedContentAccumulator {
  private let lock = NSLock()
  private let maxMedia: Int
  private let maxUrls: Int

  private(set) var files: [SharedFile] = []
  private(set) var urls: [URL] = []
  private(set) var textParts: [String] = []
  private var fileDedupKeys: Set<String> = []

  init(maxMedia: Int, maxUrls: Int) {
    self.maxMedia = maxMedia
    self.maxUrls = maxUrls
  }

  func addFile(_ file: SharedFile) {
    lock.lock()
    defer { lock.unlock() }
    guard files.count < maxMedia else { return }
    let sizeKey = file.fileSize.map(String.init) ?? "unknown"
    let key = "\(file.fileType.rawValue)|\(file.fileName)|\(sizeKey)"
    guard !fileDedupKeys.contains(key) else { return }
    fileDedupKeys.insert(key)
    files.append(file)
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
    SharedContent(files: files, urls: urls, textParts: textParts)
  }
}

/// Manages the state and operations for the share extension
/// Handles loading shared content, uploading files, and sending messages
@MainActor
class ShareState: ObservableObject {
  private nonisolated static let maxMedia = 10
  private nonisolated static let maxUrls = 10
  private static let imageCompressionQuality: CGFloat = 0.7
  private static let maxFileSizeBytes: Int64 = 100 * 1024 * 1024 // 100MB

  @Published var sharedContent: SharedContent? = nil
  @Published var sharedData: SharedData?
  @Published var isLoadingContent: Bool = false
  @Published var isSending: Bool = false
  @Published var isSent: Bool = false
  @Published var uploadProgress: Double = 0
  @Published var errorState: ErrorState?

  private nonisolated let log = Log.scoped("ShareState")
  private nonisolated let shareSessionId = UUID().uuidString
  private nonisolated let realtimeConnectWarmupSeconds: TimeInterval = 2
  private nonisolated let realtimeConnectRetrySeconds: TimeInterval = 8
  private nonisolated let sendTimeoutSeconds: TimeInterval = 12
  @MainActor private var hasStartedRealtime: Bool = false

  private nonisolated func tagged(_ message: String) -> String {
    "[share \(shareSessionId)] \(message)"
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

  private nonisolated func transcodePhotoToJpeg(_ data: Data) -> Data? {
    guard let image = UIImage(data: data) else { return nil }
    return image.jpegData(compressionQuality: Self.imageCompressionQuality)
  }

  private nonisolated func isSupportedPhotoMimeType(_ mimeType: MIMEType) -> Bool {
    let lowercased = mimeType.text.lowercased()
    return lowercased == "image/jpeg" || lowercased == "image/png" || lowercased == "image/gif"
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

    if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) ||
        identifiers.contains(UTType.fileURL.identifier) {
      return (UTType.fileURL.identifier, .document)
    }

    if let pdfType = identifiers.first(where: { UTType($0)?.conforms(to: .pdf) == true }) {
      return (pdfType, .document)
    }

    if let movieType = identifiers.first(where: { UTType($0)?.conforms(to: .movie) == true }) {
      return (movieType, .video)
    }

    if !suggestedPrefersDocument,
       let imageType = identifiers.first(where: { UTType($0)?.conforms(to: .image) == true })
    {
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

    if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
      return (UTType.fileURL.identifier, .document)
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
    let suggested = suggestedName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    var fileName = suggested
    if fileName.isEmpty {
      let fallback = fallbackURL?.lastPathComponent ?? ""
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
    try fileManager.copyItem(at: sourceURL, to: destinationURL)
    return destinationURL
  }

  private nonisolated func writeDataToTemporaryLocation(
    _ data: Data,
    suggestedName: String?,
    typeIdentifier: String?
  ) throws -> URL {
    let fileManager = FileManager.default
    let fileName = sanitizedFileName(
      suggestedName: suggestedName,
      fallbackURL: nil,
      typeIdentifier: typeIdentifier
    )
    let destinationURL = fileManager.temporaryDirectory
      .appendingPathComponent("\(UUID().uuidString)_\(fileName)")
    try data.write(to: destinationURL, options: .atomic)
    return destinationURL
  }

  private nonisolated func addFile(
    from url: URL,
    suggestedName: String?,
    typeIdentifier: String?,
    fileType: MessageFileType,
    accumulator: SharedContentAccumulator
  ) {
    do {
      let tempURL = try copyToTemporaryLocation(
        from: url,
        suggestedName: suggestedName,
        typeIdentifier: typeIdentifier
      )
      let fileName = sanitizedFileName(
        suggestedName: suggestedName,
        fallbackURL: url,
        typeIdentifier: typeIdentifier
      )
      let mimeType = resolveMimeType(
        fileURL: tempURL,
        suggestedName: fileName,
        typeIdentifier: typeIdentifier
      )
      var resolvedFileType = fileType
      if fileType == .photo &&
          (shouldTranscodePhotoToJpeg(
            suggestedName: fileName,
            typeIdentifier: typeIdentifier,
            mimeType: mimeType
          ) || !isSupportedPhotoMimeType(mimeType))
      {
        do {
          let data = try Data(contentsOf: tempURL)
          if let jpegData = transcodePhotoToJpeg(data) {
            addFile(
              from: jpegData,
              suggestedName: jpegFileName(from: fileName),
              typeIdentifier: UTType.jpeg.identifier,
              fileType: .photo,
              mimeTypeOverride: MIMEType(text: "image/jpeg"),
              accumulator: accumulator
            )
            return
          }
          let shouldFallback = shouldTranscodePhotoToJpeg(
            suggestedName: fileName,
            typeIdentifier: typeIdentifier,
            mimeType: mimeType
          )
          if shouldFallback {
            resolvedFileType = .document
            log.warning(tagged("Failed to transcode HEIC photo; falling back to document"))
          } else {
            resolvedFileType = .document
            log.warning(tagged("Unsupported photo MIME type; falling back to document (\(mimeType.text))"))
          }
        } catch {
          resolvedFileType = .document
          log.error(tagged("Failed to read shared photo data; falling back to document"), error: error)
        }
      }
      let fileSize = try? tempURL.resourceValues(forKeys: [.fileSizeKey]).fileSize
      accumulator.addFile(SharedFile(
        url: tempURL,
        fileName: fileName,
        mimeType: mimeType,
        fileType: resolvedFileType,
        fileSize: fileSize.map { Int64($0) }
      ))
    } catch {
      log.error(tagged("Failed to prepare shared file"), error: error)
    }
  }

  private nonisolated func addFile(
    from data: Data,
    suggestedName: String?,
    typeIdentifier: String?,
    fileType: MessageFileType,
    mimeTypeOverride: MIMEType? = nil,
    accumulator: SharedContentAccumulator
  ) {
    do {
      let fileName = sanitizedFileName(
        suggestedName: suggestedName,
        fallbackURL: nil,
        typeIdentifier: typeIdentifier
      )
      let resolvedMimeType = mimeTypeOverride ?? resolveMimeType(
        fileURL: nil,
        suggestedName: fileName,
        typeIdentifier: typeIdentifier
      )
      var resolvedFileType = fileType
      if fileType == .photo && mimeTypeOverride == nil &&
          (shouldTranscodePhotoToJpeg(
            suggestedName: fileName,
            typeIdentifier: typeIdentifier,
            mimeType: resolvedMimeType
          ) || !isSupportedPhotoMimeType(resolvedMimeType))
      {
        if let jpegData = transcodePhotoToJpeg(data) {
          addFile(
            from: jpegData,
            suggestedName: jpegFileName(from: fileName),
            typeIdentifier: UTType.jpeg.identifier,
            fileType: .photo,
            mimeTypeOverride: MIMEType(text: "image/jpeg"),
            accumulator: accumulator
          )
          return
        }
        let shouldFallback = shouldTranscodePhotoToJpeg(
          suggestedName: fileName,
          typeIdentifier: typeIdentifier,
          mimeType: resolvedMimeType
        )
        if shouldFallback {
          resolvedFileType = .document
          log.warning(tagged("Failed to transcode HEIC photo; falling back to document"))
        } else {
          resolvedFileType = .document
          log.warning(tagged("Unsupported photo MIME type; falling back to document (\(resolvedMimeType.text))"))
        }
      }
      let tempURL = try writeDataToTemporaryLocation(
        data,
        suggestedName: fileName,
        typeIdentifier: typeIdentifier
      )
      let mimeType = mimeTypeOverride ?? resolveMimeType(
        fileURL: tempURL,
        suggestedName: fileName,
        typeIdentifier: typeIdentifier
      )
      accumulator.addFile(SharedFile(
        url: tempURL,
        fileName: fileName,
        mimeType: mimeType,
        fileType: resolvedFileType,
        fileSize: Int64(data.count)
      ))
    } catch {
      log.error(tagged("Failed to write shared file"), error: error)
    }
  }

  private nonisolated func handleLoadedFileItem(
    _ item: NSSecureCoding?,
    typeIdentifier: String,
    fileType: MessageFileType,
    suggestedName: String?,
    accumulator: SharedContentAccumulator
  ) {
    if let url = item as? URL {
      let resolvedType = fileType == .document
        ? inferredFileType(for: url, typeIdentifier: typeIdentifier, suggestedName: suggestedName)
        : fileType
      addFile(
        from: url,
        suggestedName: suggestedName,
        typeIdentifier: typeIdentifier,
        fileType: resolvedType,
        accumulator: accumulator
      )
      return
    }

    if let data = item as? Data {
      addFile(
        from: data,
        suggestedName: suggestedName,
        typeIdentifier: typeIdentifier,
        fileType: fileType,
        accumulator: accumulator
      )
      return
    }

    if let image = item as? UIImage, fileType == .photo {
      guard let jpegData = image.jpegData(compressionQuality: Self.imageCompressionQuality) else {
        log.error(tagged("Failed to encode shared image"))
        return
      }

      addFile(
        from: jpegData,
        suggestedName: suggestedName ?? "shared_image.jpg",
        typeIdentifier: UTType.jpeg.identifier,
        fileType: .photo,
        mimeTypeOverride: MIMEType(text: "image/jpeg"),
        accumulator: accumulator
      )
      return
    }

    log.warning(tagged("Unsupported item payload for type \(typeIdentifier)"))
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
      thumbnailMimeType: thumbnailPayload?.mimeType
    )
  }

  private nonisolated func prepareVideoForUpload(
    _ file: SharedFile
  ) async throws -> (url: URL, fileName: String, mimeType: MIMEType, cleanup: (() -> Void)?) {
    let needsMp4Transcode = file.url.pathExtension.lowercased() != "mp4"
    let options = VideoCompressionOptions.uploadDefault(forceTranscode: needsMp4Transcode)

    do {
      let result = try await VideoCompressor.shared.compressVideo(at: file.url, options: options)
      let baseName = (file.fileName as NSString).deletingPathExtension
      let resolvedName = baseName.isEmpty ? "video.mp4" : "\(baseName).mp4"
      let mimeType = MIMEType(text: FileHelpers.getMimeType(for: result.url))
      let cleanup: (() -> Void)? = {
        _ = try? FileManager.default.removeItem(at: result.url)
      }
      return (result.url, resolvedName, mimeType, cleanup)
    } catch VideoCompressionError.compressionNotNeeded, VideoCompressionError.compressionNotEffective {
      if needsMp4Transcode {
        throw NSError(
          domain: "ShareError",
          code: 11,
          userInfo: [NSLocalizedDescriptionKey: "Failed to convert video to MP4."]
        )
      }
      return (file.url, file.fileName, file.mimeType, nil)
    } catch {
      if needsMp4Transcode {
        throw NSError(
          domain: "ShareError",
          code: 12,
          userInfo: [NSLocalizedDescriptionKey: "Failed to compress video for upload."]
        )
      }
      return (file.url, file.fileName, file.mimeType, nil)
    }
  }

  private nonisolated func generateVideoThumbnail(
    from asset: AVAsset,
    durationSeconds: Double
  ) throws -> (data: Data, mimeType: MIMEType)? {
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true

    let captureTime = CMTime(seconds: max(0, min(durationSeconds * 0.1, 1.0)), preferredTimescale: 600)
    let cgImage = try generator.copyCGImage(at: captureTime, actualTime: nil)
    let image = UIImage(cgImage: cgImage)
    guard let jpegData = image.jpegData(compressionQuality: 0.7) else {
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
    try await withThrowingTaskGroup(of: RpcResult.OneOf_Result?.self) { group in
      group.addTask {
        try await Realtime.shared.invoke(
          .sendMessage,
          input: .sendMessage(input),
          // Queue during connection warmup; share extension enforces its own timeout below.
          discardIfNotConnected: false
        )
      }

      group.addTask {
        try await Task.sleep(for: .seconds(timeoutSeconds))
        throw NSError(
          domain: "ShareError",
          code: 15,
          userInfo: [NSLocalizedDescriptionKey: "Inline couldn't reach the server."]
        )
      }

      let result = try await group.next()!
      group.cancelAll()
      return result
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

  func prepareConnection() async {
    if Auth.shared.getToken() == nil {
      await Auth.shared.refreshFromStorage()
    }
    await startRealtimeIfNeeded()
  }

  func loadSharedContent(from extensionItems: [NSExtensionItem]) {
    log.info(tagged("Loading shared content (\(extensionItems.count) extension items)"))
    isLoadingContent = true
    errorState = nil
    sharedContent = nil
    let group = DispatchGroup()
    let accumulator = SharedContentAccumulator(
      maxMedia: Self.maxMedia,
      maxUrls: Self.maxUrls
    )
    var totalMediaAttachments = 0
    var totalUrlAttachments = 0
    var totalTextAttachments = 0

    for extensionItem in extensionItems {
      if let attributedText = extensionItem.attributedContentText?.string {
        accumulator.addText(attributedText)
        totalTextAttachments += 1
      }
      guard let attachments = extensionItem.attachments else { continue }

      for attachment in attachments {
        if let fileTypeInfo = preferredFileType(
          for: attachment,
          suggestedName: attachment.suggestedName
        ) {
          totalMediaAttachments += 1
          let typeIdentifier = fileTypeInfo.identifier
          let fileType = fileTypeInfo.fileType
          group.enter()
          if typeIdentifier == UTType.fileURL.identifier {
            attachment.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { [weak self] item, error in
              defer { group.leave() }
              guard let self else { return }
              if let error {
                self.log.error(self.tagged("Failed to load file URL item"), error: error)
              }
              self.handleLoadedURLItem(
                item,
                suggestedName: attachment.suggestedName,
                accumulator: accumulator
              )
            }
          } else {
            attachment.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { [weak self] url, error in
              guard let self else {
                group.leave()
                return
              }
              if let error {
                self.log.error(self.tagged("Failed to load file representation"), error: error)
              }
              if let url {
                let resolvedType = fileType == .document
                  ? self.inferredFileType(
                    for: url,
                    typeIdentifier: typeIdentifier,
                    suggestedName: attachment.suggestedName
                  )
                  : fileType
                self.addFile(
                  from: url,
                  suggestedName: attachment.suggestedName,
                  typeIdentifier: typeIdentifier,
                  fileType: resolvedType,
                  accumulator: accumulator
                )
                group.leave()
                return
              }

              attachment.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { [weak self] item, error in
                defer { group.leave() }
                guard let self else { return }
                if let error {
                  self.log.error(self.tagged("Failed to load item"), error: error)
                }
                self.handleLoadedFileItem(
                  item,
                  typeIdentifier: typeIdentifier,
                  fileType: fileType,
                  suggestedName: attachment.suggestedName,
                  accumulator: accumulator
                )
              }
            }
          }
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
              suggestedName: attachment.suggestedName,
              accumulator: accumulator
            )
          }
          continue
        }

        if attachment.hasItemConformingToTypeIdentifier(UTType.text.identifier) ||
            attachment.hasItemConformingToTypeIdentifier(UTType.plainText.identifier)
        {
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

        log.warning(tagged("Unsupported share attachment types: \(attachment.registeredTypeIdentifiers)"))
      }
    }

    // Wait for all items to load and then process the results
    group.notify(queue: .main) { [weak self] in
      guard let self else { return }
      let content = accumulator.finalize()
      self.isLoadingContent = false
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
      }
      if totalUrlAttachments > Self.maxUrls {
        self.log.warning(self.tagged("Limited to \(Self.maxUrls) URLs out of \(totalUrlAttachments) provided"))
      }
      if totalTextAttachments == 0, content.totalItemCount == 0 {
        self.log.warning(self.tagged("No usable share content found"))
      }
    }
  }

  func sendMessage(caption: String, selectedChat: SharedChat, completion: @escaping () -> Void) {
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

    if Auth.shared.getToken() == nil {
      log.warning(tagged("Missing auth token for share; attempting refresh"))
    }

    isSending = true
    isSent = false
    uploadProgress = 0

    let messageText = combinedMessageText(caption: caption, content: sharedContent)
    let content = sharedContent

    Task.detached(priority: .userInitiated) { [weak self] in
      guard let self else { return }
      do {
        let apiClient = ApiClient.shared
        let sendStart = Date()
        let connectionWarmup = Task {
          await self.startRealtimeIfNeeded()
          _ = await self.waitForRealtimeConnected(maxSeconds: self.realtimeConnectWarmupSeconds)
        }
        let totalMediaItems = content.mediaCount
        let totalItems = max(totalMediaItems, 1)
        var processedItems = 0
        var didSendText = false

        if !content.files.isEmpty {
          self.log.info(self.tagged("Sending \(content.files.count) attachments"))
        }

        for file in content.files {
          self.log.debug(self.tagged("Uploading \(file.fileName) (\(file.fileSize ?? 0) bytes) as \(file.fileType)"))
          if file.fileType != .video, let fileSize = file.fileSize, fileSize > Self.maxFileSizeBytes {
            throw NSError(
              domain: "ShareError",
              code: 3,
              userInfo: [
                NSLocalizedDescriptionKey: "\(file.fileName) is too large. Maximum size is 100MB."
              ]
            )
          }

          let uploadResult: InlineKit.UploadFileResult
          let itemIndex = processedItems
          let progressHandler: (Double) -> Void = { [weak self] progress in
            let itemProgress = (Double(itemIndex) + progress) / Double(totalItems)
            Task { @MainActor in
              self?.uploadProgress = itemProgress * 0.9
            }
          }
          switch file.fileType {
            case .photo:
              let fileData = try Data(contentsOf: file.url, options: .mappedIfSafe)
              guard fileData.count <= Self.maxFileSizeBytes else {
                throw NSError(
                  domain: "ShareError",
                  code: 3,
                  userInfo: [
                    NSLocalizedDescriptionKey: "\(file.fileName) is too large. Maximum size is 100MB."
                  ]
                )
              }
              uploadResult = try await apiClient.uploadFile(
                type: .photo,
                data: fileData,
                filename: file.fileName,
                mimeType: file.mimeType,
                progress: progressHandler
              )
            case .document:
              let fileData = try Data(contentsOf: file.url, options: .mappedIfSafe)
              guard fileData.count <= Self.maxFileSizeBytes else {
                throw NSError(
                  domain: "ShareError",
                  code: 3,
                  userInfo: [
                    NSLocalizedDescriptionKey: "\(file.fileName) is too large. Maximum size is 100MB."
                  ]
                )
              }
              uploadResult = try await apiClient.uploadFile(
                type: .document,
                data: fileData,
                filename: file.fileName,
                mimeType: file.mimeType,
                progress: progressHandler
              )
            case .video:
              let prepared = try await prepareVideoForUpload(file)
              defer { prepared.cleanup?() }
              let fileData = try Data(contentsOf: prepared.url, options: .mappedIfSafe)
              guard fileData.count <= Self.maxFileSizeBytes else {
                throw NSError(
                  domain: "ShareError",
                  code: 3,
                  userInfo: [
                    NSLocalizedDescriptionKey: "\(prepared.fileName) is too large. Maximum size is 100MB."
                  ]
                )
              }
              let videoMetadata = try await buildVideoMetadata(from: prepared.url)
              uploadResult = try await apiClient.uploadFile(
                type: .video,
                data: fileData,
                filename: prepared.fileName,
                mimeType: prepared.mimeType,
                videoMetadata: videoMetadata,
                progress: progressHandler
              )
          }

          let fileText = (!didSendText && messageText != nil) ? messageText : nil
          await connectionWarmup.value
          let media = try inputMedia(for: file.fileType, uploadResult: uploadResult)
          try await sendMessageToChat(
            selectedChat,
            text: fileText,
            media: media
          )

          didSendText = didSendText || (messageText != nil)
          processedItems += 1
          await MainActor.run {
            self.uploadProgress = Double(processedItems) / Double(totalItems) * 0.9
          }
          self.log.debug(self.tagged("Sent \(processedItems) of \(totalItems) items"))
        }

        if totalMediaItems == 0, let messageText {
          await connectionWarmup.value
          try await sendMessageToChat(selectedChat, text: messageText, media: nil)
          await MainActor.run {
            self.uploadProgress = 0.9
          }
        } else if totalMediaItems > 0, messageText == nil {
          await MainActor.run {
            self.uploadProgress = 0.9
          }
        }

        await MainActor.run {
          self.isSending = false
          self.isSent = true
          self.uploadProgress = 1.0

          // Play haptic feedback
          let impactFeedback = UIImpactFeedbackGenerator(style: .light)
          impactFeedback.impactOccurred()

          // Close after delay
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            completion()
          }
        }
        self.log.info(self.tagged("Share completed in \(Date().timeIntervalSince(sendStart))s"))
      } catch {
        self.log.error(self.tagged("Failed to share content"), error: error)
        
        await MainActor.run {
          // Provide more specific error messages
          let errorMessage: (title: String, message: String, suggestion: String?) = {
            if let apiError = error as? APIError {
              switch apiError {
                case .networkError:
                  return ("Connection Error", "Unable to connect to the server.", "Check your internet connection and try again.")
                case .rateLimited:
                  return ("Rate Limited", "Too many requests. Please wait a moment.", "Try again in a few seconds.")
                case let .httpError(statusCode):
                  if statusCode == 401 || statusCode == 403 {
                    return ("Sign In Required", "Your session has expired.", "Open the Inline app and try again.")
                  }
                  return ("Server Error", "Server returned error code \(statusCode).", "Please try again later.")
                case let .error(error, _, description):
                  return ("Share Failed", description ?? error, "Please try again.")
                default:
                  return ("Share Failed", "Could not share the content.", "Please check your connection and try again.")
              }
            }

            if let realtimeError = error as? RealtimeAPIError {
              switch realtimeError {
                case .notAuthorized:
                  return ("Sign In Required", "Your session has expired.", "Open the Inline app and try again.")
                case .notConnected:
                  return ("Connection Error", "Inline couldn't reach the server.", "Check your internet connection and try again.")
                case let .rpcError(_, message, _):
                  return ("Share Failed", message ?? "The server rejected the message.", "Please try again.")
                default:
                  return ("Share Failed", "Could not share the content.", "Please try again.")
              }
            }

            let nsError = error as NSError
            if nsError.domain == "ShareError" {
              switch nsError.code {
                case 13:
                  return ("Sign In Required", nsError.localizedDescription, "Open the Inline app and try again.")
                case 15:
                  return ("Connection Error", nsError.localizedDescription, "Check your internet connection and try again.")
                case 14:
                  return ("Connection Error", nsError.localizedDescription, "Check your internet connection and try again.")
                default:
                  return ("Share Failed", nsError.localizedDescription, "Please try again.")
              }
            }

            return ("Share Failed", "An unexpected error occurred.", "Please try again.")
          }()
          
          self.errorState = ErrorState(
            title: errorMessage.title,
            message: errorMessage.message,
            suggestion: errorMessage.suggestion
          )
          self.isSending = false
        }
      }
    }
  }
}
