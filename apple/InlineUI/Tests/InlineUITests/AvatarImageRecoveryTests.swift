#if os(macOS)
import AppKit
import Foundation
import Kingfisher
import SwiftUI
import Synchronization
import Testing
@testable import InlineUI

/// URLProtocol supplies the network boundary only: Kingfisher downloads, decodes, caches and retries.
private final class AvatarTestProtocol: URLProtocol, @unchecked Sendable {
  struct Route: Sendable {
    var replies: [Reply]
    var requests = 0
  }
  enum Reply: Sendable { case status(Int), network(Int), image(Data), malformed, pending }
  static let routes = Mutex<[String: Route]>([:])
  static let pending = Mutex<[String: AvatarTestProtocol]>([:])
  static let stops = Mutex<[String: Int]>([:])

  static func install(_ replies: [Reply]) -> URL {
    let url = URL(string: "https://avatar.invalid/\(UUID().uuidString)")!
    routes.withLock { $0[url.absoluteString] = Route(replies: replies) }
    return url
  }
  static func count(_ url: URL) -> Int { routes.withLock { $0[url.absoluteString]?.requests ?? 0 } }
  override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "avatar.invalid" }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    guard let url = request.url else { return }
    let reply: Reply = Self.routes.withLock {
      guard var route = $0[url.absoluteString] else { return .status(404) }
      let reply = route.replies[min(route.requests, route.replies.count - 1)]
      route.requests += 1
      $0[url.absoluteString] = route
      return reply
    }
    if case .pending = reply {
      Self.pending.withLock { $0[url.absoluteString] = self }
      return
    }
    if case .network(let code) = reply {
      client?.urlProtocol(self, didFailWithError: URLError(URLError.Code(rawValue: code)))
      return
    }
    let status: Int
    let data: Data
    switch reply {
    case .status(let value): status = value; data = Data()
    case .image(let value): status = 200; data = value
    default: status = 200; data = Data("not an image".utf8)
    }
    client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status,
                                                       httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: data)
    client?.urlProtocolDidFinishLoading(self)
  }
  static func finish(_ url: URL, data: Data) {
    guard let task = pending.withLock({ $0.removeValue(forKey: url.absoluteString) }) else { return }
    task.client?.urlProtocol(task, didReceive: HTTPURLResponse(url: url, statusCode: 200,
                                                            httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
    task.client?.urlProtocol(task, didLoad: data)
    task.client?.urlProtocolDidFinishLoading(task)
  }
  override func stopLoading() {
    guard let url = request.url else { return }
    Self.stops.withLock { $0[url.absoluteString, default: 0] += 1 }
    Self.pending.withLock { _ = $0.removeValue(forKey: url.absoluteString) }
  }
}

@Suite("Avatar image recovery", .serialized)
@MainActor
struct AvatarImageRecoveryTests {
  private func png(_ color: NSColor = .red) throws -> Data {
    let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 16,
                                             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                             isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
    for x in 0..<16 { for y in 0..<16 { bitmap.setColor(color, atX: x, y: y) } }
    return try #require(bitmap.representation(using: .png, properties: [:]))
  }

  private func manager() -> KingfisherManager {
    let downloader = ImageDownloader(name: UUID().uuidString)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [AvatarTestProtocol.self]
    downloader.sessionConfiguration = configuration
    return KingfisherManager(downloader: downloader, cache: ImageCache(name: UUID().uuidString))
  }

  private func source(_ url: URL, local: URL? = nil, identity: String = "unique:test") throws -> UserAvatarImageSource {
    try #require(UserAvatarImageSource(userID: 42, identity: identity, remoteURL: url, localURL: local, scale: 1))
  }

  private func settle(_ loader: AvatarImageLoader) async throws {
    for _ in 0..<200 {
      if loader.image != nil || loader.failure != nil { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("Avatar loader did not settle")
  }

  @Test("fresh URL repairs a failed source without changing the byte cache key")
  func changedRemoteSource() async throws {
    let old = AvatarTestProtocol.install([.status(403)])
    let fresh = AvatarTestProtocol.install([.image(try png())])
    let manager = manager()
    let original = try #require(UserAvatarImageSource(userID: 42, identity: "unique:photo", remoteURL: old,
                                                    localURL: nil, scale: 1))
    let repaired = try #require(UserAvatarImageSource(userID: 42, identity: "unique:photo", remoteURL: fresh,
                                                    localURL: nil, scale: 1))
    #expect(original != repaired)
    #expect(original.cacheKey == repaired.cacheKey)
    do {
      _ = try await original.originalImageData(using: manager)
      Issue.record("Old source should fail")
    } catch {}
    #expect(try await !repaired.originalImageData(using: manager).isEmpty)
    #expect(AvatarTestProtocol.count(old) == 1)
    #expect(AvatarTestProtocol.count(fresh) == 1)
    _ = try await original.originalImageData(using: manager, onlyFromCache: true)
    #expect(AvatarTestProtocol.count(old) == 1)
  }

  @Test("persisted local source is selected immediately and missing local file falls back through loader")
  func localSourceAndFallback() async throws {
    let remote = AvatarTestProtocol.install([.image(try png())])
    let local = FileManager.default.temporaryDirectory.appendingPathComponent("RemoteUserAvatar-v1-\(UUID().uuidString).png")
    // Leave this unique path absent. Source construction must not touch the filesystem.
    let source = try #require(UserAvatarImageSource(userID: 42, identity: "unique:photo", remoteURL: remote,
                                                  localURL: local, scale: 1))
    #expect(source.url == local)
    #expect(source.fallbackURL == remote)
    #expect(try await !source.originalImageData(using: manager()).isEmpty)
    #expect(AvatarTestProtocol.count(remote) == 1)
  }

  @Test("photo lifetime changes with source and processing configuration")
  func photoProcessingIdentity() throws {
    let source = try source(AvatarTestProtocol.install([.image(try png())]))
    let initial = UserAvatarPhotoIdentity(source: source, size: 22, scale: 1)
    #expect(initial != UserAvatarPhotoIdentity(source: source, size: 40, scale: 1))
    #expect(initial != UserAvatarPhotoIdentity(source: source, size: 22, scale: 2))
  }

  @Test("missing local file reports the remote success URL for persistent cache repair")
  func fallbackSuccessURL() async throws {
    let remote = AvatarTestProtocol.install([.image(try png())])
    let local = FileManager.default.temporaryDirectory.appendingPathComponent("RemoteUserAvatar-v1-\(UUID().uuidString).png")
    let loader = AvatarImageLoader(manager: manager(), accountIsCurrent: { true })
    var loadedURL: URL?
    loader.start(source: try source(remote, local: local), size: 32, scale: 1) { loadedURL = $0 }
    try await settle(loader)
    #expect(loader.image != nil)
    #expect(loadedURL == remote)
  }

  @Test("real loader retries one transient error and decodes the successful response")
  func transientRecovery() async throws {
    let url = AvatarTestProtocol.install([.network(NSURLErrorTimedOut), .image(try png())])
    let loader = AvatarImageLoader(manager: manager(), delay: .milliseconds(20), accountIsCurrent: { true })
    loader.start(source: try source(url), size: 32, scale: 1)
    try await settle(loader)
    #expect(loader.image != nil)
    #expect(AvatarTestProtocol.count(url) == 2)
  }

  @Test("permanent HTTP and malformed image never retry", arguments: [false, true])
  func terminalFailure(malformed: Bool) async throws {
    let url = AvatarTestProtocol.install([malformed ? .malformed : .status(403)])
    let loader = AvatarImageLoader(manager: manager(), delay: .milliseconds(20), accountIsCurrent: { true })
    loader.start(source: try source(url), size: 32, scale: 1)
    try await settle(loader)
    #expect(loader.failure == (malformed ? .decode : .httpPermanent))
    #expect(AvatarTestProtocol.count(url) == 1)
  }

  @Test("permanent transient failure is bounded even on repeated appearances")
  func boundedFailure() async throws {
    let url = AvatarTestProtocol.install([.status(503)])
    let loader = AvatarImageLoader(manager: manager(), delay: .milliseconds(20), accountIsCurrent: { true })
    let source = try source(url)
    loader.start(source: source, size: 32, scale: 1)
    try await settle(loader)
    #expect(AvatarTestProtocol.count(url) == 2)
    loader.cancel()
    loader.start(source: source, size: 32, scale: 1)
    try await Task.sleep(for: .milliseconds(100))
    #expect(AvatarTestProtocol.count(url) == 3)
  }

  @Test("disappearance or account replacement revokes a delayed retry", arguments: [false, true])
  func revokePendingRetry(accountChange: Bool) async throws {
    let url = AvatarTestProtocol.install([.status(503), .image(try png())])
    var current = true
    let loader = AvatarImageLoader(manager: manager(), delay: .milliseconds(150), accountIsCurrent: { current })
    loader.start(source: try source(url), size: 32, scale: 1)
    while AvatarTestProtocol.count(url) == 0 { try await Task.sleep(for: .milliseconds(5)) }
    try await Task.sleep(for: .milliseconds(30))
    if accountChange { current = false } else { loader.cancel() }
    try await Task.sleep(for: .milliseconds(200))
    #expect(loader.image == nil)
    #expect(AvatarTestProtocol.count(url) == 1)
  }

  @Test("disappearance cancels the replacement request after retry starts")
  func cancelActiveRetry() async throws {
    let url = AvatarTestProtocol.install([.status(503), .pending])
    let loader = AvatarImageLoader(manager: manager(), delay: .milliseconds(20), accountIsCurrent: { true })
    loader.start(source: try source(url), size: 32, scale: 1)
    for _ in 0..<100 where AvatarTestProtocol.count(url) < 2 { try await Task.sleep(for: .milliseconds(10)) }
    #expect(AvatarTestProtocol.count(url) == 2)
    loader.cancel()
    try await Task.sleep(for: .milliseconds(100))
    #expect(AvatarTestProtocol.stops.withLock { $0[url.absoluteString, default: 0] } > 0)
    #expect(loader.image == nil)
    #expect(loader.failure == nil)
  }

  @Test("a late successful download cannot display after account replacement")
  func rejectLateAccountCompletion() async throws {
    let url = AvatarTestProtocol.install([.pending])
    var current = true
    let loader = AvatarImageLoader(manager: manager(), accountIsCurrent: { current })
    loader.start(source: try source(url), size: 32, scale: 1)
    for _ in 0..<100 where AvatarTestProtocol.count(url) == 0 { try await Task.sleep(for: .milliseconds(10)) }
    current = false
    AvatarTestProtocol.finish(url, data: try png())
    try await Task.sleep(for: .milliseconds(100))
    #expect(loader.image == nil)
    #expect(loader.currentAccount == nil)
  }

  @Test("same-source simultaneous avatars share the downloader retry")
  func coalescedRecovery() async throws {
    let url = AvatarTestProtocol.install([.status(503), .image(try png())])
    let manager = manager()
    let first = AvatarImageLoader(manager: manager, delay: .milliseconds(100), accountIsCurrent: { true })
    let second = AvatarImageLoader(manager: manager, delay: .milliseconds(100), accountIsCurrent: { true })
    first.start(source: try source(url), size: 22, scale: 1)
    second.start(source: try source(url), size: 40, scale: 1)
    try await settle(first); try await settle(second)
    #expect(first.image != nil && second.image != nil)
    #expect(AvatarTestProtocol.count(url) == 2)
  }

  @Test("local fallback gets its own remote retry and replacement revokes old delayed work")
  func localFallbackAndReplacement() async throws {
    let remote = AvatarTestProtocol.install([.status(503), .image(try png())])
    let local = URL(fileURLWithPath: "/nonexistent/RemoteUserAvatar-v1-absent.png")
    let loader = AvatarImageLoader(manager: manager(), delay: .milliseconds(20), accountIsCurrent: { true })
    loader.start(source: try source(remote, local: local), size: 32, scale: 1)
    try await settle(loader)
    #expect(loader.image != nil)
    #expect(AvatarTestProtocol.count(remote) == 2)

    let old = AvatarTestProtocol.install([.status(503)])
    let next = AvatarTestProtocol.install([.image(try png(.green))])
    let changing = AvatarImageLoader(manager: manager(), delay: .milliseconds(150), accountIsCurrent: { true })
    changing.start(source: try source(old), size: 32, scale: 1)
    while AvatarTestProtocol.count(old) == 0 { try await Task.sleep(for: .milliseconds(5)) }
    changing.start(source: try source(next, identity: "unique:replacement"), size: 32, scale: 1)
    try await settle(changing)
    try await Task.sleep(for: .milliseconds(200))
    #expect(AvatarTestProtocol.count(old) == 1)
    #expect(AvatarTestProtocol.count(next) == 1)
    #expect(changing.image != nil)
  }

  @Test("mounted avatar recovers without a navigation or appearance cycle")
  func mountedRecovery() async throws {
    let url = AvatarTestProtocol.install([.network(NSURLErrorTimedOut), .image(try png())])
    let loader = AvatarImageLoader(manager: manager(), delay: .milliseconds(50), accountIsCurrent: { true })
    let host = NSHostingView(rootView: UserAvatarPhoto(
      source: try source(url), size: 32, scale: 1, userID: 42, photoIdentity: "unique:test", cacheRemoteAvatar: false,
      loader: loader
    ).frame(width: 32, height: 32))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 32, height: 32),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    window.orderBack(nil)
    defer { window.orderOut(nil); window.contentView = nil }
    try await settle(loader)
    #expect(AvatarTestProtocol.count(url) == 2)
    try await Task.sleep(for: .milliseconds(100))
    host.layoutSubtreeIfNeeded()
    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: bitmap)
    let pixel = try #require(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.deviceRGB))
    #expect(pixel.redComponent > 0.9 && pixel.greenComponent < 0.1)
  }

  @Test("prepared local bytes render immediately from the existing processed cache")
  func cachedFirstFrame() async throws {
    let local = FileManager.default.temporaryDirectory.appendingPathComponent("RemoteUserAvatar-v1-\(UUID().uuidString).png")
    try png().write(to: local)
    let source = try source(URL(string: "https://avatar.invalid/unused")!, local: local)
    let manager = manager()
    let prepared = AvatarImageLoader(manager: manager, accountIsCurrent: { true })
    prepared.start(source: source, size: 32, scale: 1)
    try await settle(prepared)
    let firstFrame = AvatarImageLoader(manager: manager, accountIsCurrent: { true })
    firstFrame.start(source: source, size: 32, scale: 1)
    #expect(firstFrame.image != nil)
    #expect(AvatarTestProtocol.count(source.fallbackURL!) == 0)
  }
}
#endif
