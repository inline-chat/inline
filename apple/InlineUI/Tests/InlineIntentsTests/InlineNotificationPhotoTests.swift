import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
import UserNotifications
@testable import InlineIntents

@Suite("Expanded notification photos")
struct InlineNotificationPhotoTests {
  @Test func optionalArtworkIsTolerantAndDoesNotCarryCredentials() {
    for json in [#"{"body":"Keep this text"}"#, #"{"photoUrl":null}"#,
                 #"{"photoUrl":42}"#, #"{"photoUrl":{"url":"https://example.com/photo"}}"#,
                 #"{"photoUrl":"http://example.com/photo"}"#, #"{"photoUrl":"https://user:pass@example.com/photo"}"#] {
      #expect(InlineNotificationPhoto.url(inDecryptedContent: Data(json.utf8)) == nil)
    }
    let data = Data(#"{"body":"Keep this text","photoUrl":"https://example.com/photo.jpg"}"#.utf8)
    #expect(InlineNotificationPhoto.url(inDecryptedContent: data)?.absoluteString == "https://example.com/photo.jpg")
  }

  @Test(arguments: [UTType.jpeg, UTType.png])
  func createsBoundedNativeAttachmentAndRemovesLocationMetadata(type: UTType) throws {
    let context = try #require(CGContext(data: nil, width: 2400, height: 1200, bitsPerComponent: 8,
      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    let image = try #require(context.makeImage())
    let input = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(input, type.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, [
      kCGImagePropertyOrientation: 6,
      kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 12.3, kCGImagePropertyGPSLongitude: 45.6],
    ] as CFDictionary)
    #expect(CGImageDestinationFinalize(destination))
    let result = try #require(InlineNotificationPhoto.normalizedImage(input as Data))
    let source = try #require(CGImageSourceCreateWithData(result.data as CFData, nil))
    let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
    #expect(properties[kCGImagePropertyPixelWidth] as? Int == 640)
    #expect(properties[kCGImagePropertyPixelHeight] as? Int == 1280)
    #expect(properties[kCGImagePropertyGPSDictionary] == nil)
    #expect(result.data.count <= InlineNotificationPhoto.maximumBytes)
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("notification-photo-test-\(UUID()).\(result.extensionName)")
    defer { try? FileManager.default.removeItem(at: url) }
    try result.data.write(to: url)
    let attachment = try UNNotificationAttachment(identifier: "message-photo", url: url)
    #expect(attachment.type == type.identifier)
  }

  @Test func rejectsInvalidUnsupportedAndOversizedData() throws {
    #expect(InlineNotificationPhoto.normalizedImage(Data()) == nil)
    #expect(InlineNotificationPhoto.normalizedImage(Data("not an image".utf8)) == nil)
    #expect(InlineNotificationPhoto.normalizedImage(Data(repeating: 0, count: InlineNotificationPhoto.maximumBytes + 1)) == nil)
    let gif = try #require(Data(base64Encoded: "R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7"))
    #expect(InlineNotificationPhoto.normalizedImage(gif) == nil)
  }

  @Test(.timeLimit(.minutes(1)), arguments: ["valid", "exact-limit", "oversize-header", "oversize-stream", "misleading-length", "not-found", "insecure"])
  func boundsNetworkData(scenario: String) async {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [PhotoProtocol.self]
    let session = InlineNotificationPhoto.makeSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let scheme = scenario == "insecure" ? "http" : "https"
    let url = URL(string: "\(scheme)://notification.invalid/\(scenario)")!
    let data = await InlineNotificationPhoto.data(from: url, session: session)
    switch scenario {
    case "valid": #expect(data == Data([1, 2, 3]))
    case "exact-limit": #expect(data?.count == InlineNotificationPhoto.maximumBytes)
    default: #expect(data == nil)
    }
    if ["oversize-header", "oversize-stream", "misleading-length"].contains(scenario) {
      await expectEvent("stopped", url: url)
    }
  }

  @Test(.timeLimit(.minutes(1))) func cancellationStopsStalledDownload() async {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [PhotoProtocol.self]
    let session = InlineNotificationPhoto.makeSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let url = URL(string: "https://notification.invalid/stalled")!
    let task = Task { await InlineNotificationPhoto.data(from: url, session: session) }
    await expectEvent("started", url: url)
    task.cancel()
    #expect(await task.value == nil)
    await expectEvent("stopped", url: url)
  }

  @Test func cancelledEnrichmentDoesNotStartANetworkRequest() async {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [PhotoProtocol.self]
    let session = InlineNotificationPhoto.makeSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let url = URL(string: "https://notification.invalid/already-cancelled")!
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return await InlineNotificationPhoto.data(from: url, session: session)
    }
    #expect(await task.value == nil)
    #expect(!PhotoProtocol.events.contains("started", url: url))
  }

  private func expectEvent(_ event: String, url: URL) async {
    for _ in 0..<100 {
      if PhotoProtocol.events.contains(event, url: url) { break }
      try? await Task.sleep(for: .milliseconds(10))
    }
    #expect(PhotoProtocol.events.contains(event, url: url))
  }
}

private final class PhotoProtocol: URLProtocol, @unchecked Sendable {
  static let events = PhotoProtocolEvents()
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    Self.events.record("started", url: request.url!)
    let path = request.url!.lastPathComponent
    if path == "stalled" { return }
    let maximum = InlineNotificationPhoto.maximumBytes
    let headers: [String: String] = switch path {
    case "oversize-header": ["Content-Length": String(maximum + 1)]
    case "misleading-length": ["Content-Length": String(maximum)]
    default: [:]
    }
    let response = HTTPURLResponse(url: request.url!, statusCode: path == "not-found" ? 404 : 200,
      httpVersion: "HTTP/1.1", headerFields: headers)!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    if path == "oversize-header" { return }
    if ["oversize-stream", "exact-limit", "misleading-length"].contains(path) {
      for _ in 0..<32 { client?.urlProtocol(self, didLoad: Data(repeating: 1, count: maximum / 32)) }
      if path != "exact-limit" {
        client?.urlProtocol(self, didLoad: Data([1]))
        return
      }
    } else {
      client?.urlProtocol(self, didLoad: Data([1, 2, 3]))
    }
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() { Self.events.record("stopped", url: request.url!) }
}

private final class PhotoProtocolEvents: @unchecked Sendable {
  private let lock = NSLock()
  private var events: Set<String> = []
  func record(_ event: String, url: URL) { lock.withLock { _ = events.insert(event + url.absoluteString) } }
  func contains(_ event: String, url: URL) -> Bool { lock.withLock { events.contains(event + url.absoluteString) } }
}
