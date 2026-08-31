import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Optional photo artwork for the system's expanded notification, never a message-view loader.
public enum InlineNotificationPhoto {
  public static let maximumBytes = 5 * 1_024 * 1_024
  public static let maximumPixelSize = 1_280

  /// Decode optional artwork independently: a wrong JSON type must never reject valid message text.
  public static func url(inDecryptedContent data: Data) -> URL? {
    struct Artwork: Decodable { let photoUrl: String? }
    guard let value = (try? JSONDecoder().decode(Artwork.self, from: data))?.photoUrl,
          let url = URL(string: value), url.scheme?.lowercased() == "https", url.host != nil,
          url.user == nil, url.password == nil
    else { return nil }
    return url
  }

  /// Returns a private, normalized image file. The caller either submits it as an
  /// attachment (the system takes ownership) or removes it if delivery already ended.
  @concurrent
  public static func file(from url: URL) async -> URL? {
    guard !Task.isCancelled else { return nil }
    let session = makeSession()
    defer { session.invalidateAndCancel() }
    guard let data = await data(from: url, session: session), !Task.isCancelled,
          let image = normalizedImage(data), !Task.isCancelled
    else { return nil }

    let fileURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("inline-notification-photo-\(UUID().uuidString).\(image.extensionName)")
    do {
      #if os(iOS)
      try image.data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
      #else
      try image.data.write(to: fileURL, options: .atomic)
      #endif
      try Task.checkCancellation()
      return fileURL
    } catch {
      try? FileManager.default.removeItem(at: fileURL)
      return nil
    }
  }

  static func makeSession(configuration: URLSessionConfiguration = .ephemeral) -> URLSession {
    configuration.httpShouldSetCookies = false
    configuration.httpCookieStorage = nil
    configuration.urlCredentialStorage = nil
    configuration.urlCache = nil
    return URLSession(configuration: configuration, delegate: PhotoRedirectPolicy(), delegateQueue: nil)
  }

  static func data(from url: URL, session: URLSession) async -> Data? {
    guard !Task.isCancelled, url.scheme?.lowercased() == "https", url.host != nil,
          url.user == nil, url.password == nil
    else { return nil }
    do {
      let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 2)
      let (bytes, response) = try await session.bytes(for: request)
      defer { bytes.task.cancel() }
      guard let response = response as? HTTPURLResponse, response.statusCode == 200,
            response.url?.scheme?.lowercased() == "https",
            response.expectedContentLength <= Int64(maximumBytes)
      else { return nil }
      return try await withTaskCancellationHandler {
        var data = Data()
        for try await byte in bytes {
          try Task.checkCancellation()
          guard data.count < maximumBytes else { return nil }
          data.append(byte)
        }
        return data
      } onCancel: {
        bytes.task.cancel()
      }
    } catch {
      return nil
    }
  }

  static func normalizedImage(_ data: Data) -> (data: Data, extensionName: String)? {
    guard !data.isEmpty, data.count <= maximumBytes,
          let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
          let type = CGImageSourceGetType(source) as String?,
          type == UTType.jpeg.identifier || type == UTType.png.identifier,
          CGImageSourceGetCount(source) == 1,
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let width = properties[kCGImagePropertyPixelWidth] as? Double,
          let height = properties[kCGImagePropertyPixelHeight] as? Double,
          width > 0, height > 0, width * height <= 40_000_000,
          let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
          ] as CFDictionary),
          CGImageSourceGetStatus(source) == .statusComplete,
          CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete
    else { return nil }

    // Re-encode the bounded preview: do not retain EXIF/location metadata or the original file.
    let output = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(output, type as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
    guard CGImageDestinationFinalize(destination), output.length <= maximumBytes else { return nil }
    return (output as Data, type == UTType.png.identifier ? "png" : "jpg")
  }
}

private final class PhotoRedirectPolicy: NSObject, URLSessionTaskDelegate {
  func urlSession(
    _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    // Signed media endpoints return the file directly; never forward a capability through a redirect.
    completionHandler(nil)
  }
}
