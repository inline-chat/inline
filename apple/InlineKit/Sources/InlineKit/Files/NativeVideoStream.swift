import AVFoundation
import Foundation
import InlineCompat
import UniformTypeIdentifiers

/// Plays a video while it downloads natively. AVFoundation's reads are served from the
/// download's partial file, and the download fetches parts from the latest read position
/// first, so playback and seeking start before the file is complete and the bytes are fetched
/// once (the player and the chat share them).
///
/// The asset's resource loader holds this object weakly: keep it while the asset plays, and
/// `close()` it when done.
public final class NativeVideoStream: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
  static let scheme = "inline-stream"

  public let asset: AVURLAsset
  private let target: NativeDownloadManager.StreamTarget
  private let manager: NativeDownloadManager
  private let contentType: String
  private let reader = UUID()
  private let queue = DispatchQueue(label: "chat.inline.native-video-stream")
  private let lock = NSLock()
  private var loads: [ObjectIdentifier: Task<Void, Never>] = [:]
  private var closed = false
  private var onClose: (@Sendable () -> Void)?

  init(
    target: NativeDownloadManager.StreamTarget, manager: NativeDownloadManager,
    contentType: String = UTType.mpeg4Movie.identifier, onClose: (@Sendable () -> Void)? = nil
  ) {
    self.target = target
    self.manager = manager
    self.contentType = contentType
    self.onClose = onClose
    // The resource loader only sees URLs whose scheme AVFoundation cannot load itself.
    var components = URLComponents()
    components.scheme = Self.scheme
    components.host = "video"
    components.path = "/\(target.message.chatID)-\(target.message.messageID).mp4"
    asset = AVURLAsset(url: components.url!)
    super.init()
    asset.resourceLoader.setDelegate(self, queue: queue)
  }

  deinit { close() }

  /// Ends this stream's reads with its download's outcome.
  func finish(_ result: Result<URL, any Error>) {
    guard lock.withLock({ !closed }) else { return }
    let manager = manager, reader = reader
    Task { [weak self] in
      await manager.finishReads(reader, result: result)
      // A close that raced ahead has already ended the reader; end what this call kept.
      if self?.isClosed ?? true { await manager.endReading(reader) }
    }
  }

  private var isClosed: Bool { lock.withLock { closed } }

  /// Stops serving reads. Bytes already downloaded stay.
  public func close() {
    let (tasks, onClose): ([Task<Void, Never>], (@Sendable () -> Void)?) = lock.withLock {
      guard !closed else { return ([], nil) }
      closed = true
      defer { loads.removeAll(); self.onClose = nil }
      return (Array(loads.values), self.onClose)
    }
    tasks.forEach { $0.cancel() }
    let manager = manager, reader = reader
    Task { await manager.endReading(reader) }
    onClose?()
  }

  public func resourceLoader(
    _: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest
  ) -> Bool {
    guard request.request.url?.scheme == Self.scheme else { return false }
    let loading = LoadingRequest(request)
    let id = ObjectIdentifier(request)
    lock.withLock {
      guard !closed else {
        request.finishLoading(with: CancellationError())
        return
      }
      loads[id] = Task { [weak self] in
        await self?.serve(loading)
        self?.lock.withLock { _ = self?.loads.removeValue(forKey: id) }
      }
    }
    return true
  }

  public func resourceLoader(_: AVAssetResourceLoader, didCancel request: AVAssetResourceLoadingRequest) {
    lock.withLock { loads.removeValue(forKey: ObjectIdentifier(request)) }?.cancel()
  }

  private func serve(_ loading: LoadingRequest) async {
    let request = loading.request
    do {
      if let information = request.contentInformationRequest {
        let (_, total) = try await manager.streamBytes(target, reader: reader, offset: 0, length: 0)
        information.contentType = contentType
        information.contentLength = Int64(total)
        information.isByteRangeAccessSupported = true
      }
      if let data = request.dataRequest {
        let requestedEnd: UInt64? = data.requestsAllDataToEndOfResource ? nil :
          UInt64(max(0, data.requestedOffset)) + UInt64(max(0, data.requestedLength))
        try await Self.serve(
          from: UInt64(max(0, data.currentOffset)), to: requestedEnd,
          bytes: { [manager, target, reader] offset, length in
            try await manager.streamBytes(target, reader: reader, offset: offset, length: length)
          },
          respond: { data.respond(with: $0) }
        )
      }
      guard !request.isCancelled else { return }
      request.finishLoading()
    } catch {
      guard !request.isCancelled else { return }
      request.finishLoading(with: error)
    }
  }

  /// Serves `[start, end)` (to the file's end when `end` is nil) one part at a time, each as
  /// soon as the download has written it.
  static func serve(
    from start: UInt64, to end: UInt64?,
    bytes: (_ offset: UInt64, _ length: UInt64) async throws -> (source: NativeDownloadManager.StreamSource, total: UInt64),
    respond: (Data) -> Void
  ) async throws {
    let partSize = UInt64(NativeFileDownloader.partSize)
    var offset = start
    var knownTotal: UInt64?
    while true {
      try Task.checkCancellation()
      if let knownTotal, offset >= min(end ?? knownTotal, knownTotal) { return }
      let partEnd = (offset / partSize + 1) * partSize
      let want = min(partEnd, end ?? partEnd) - offset
      guard want > 0 else { return }
      let (source, total) = try await bytes(offset, want)
      knownTotal = total
      let stop = min(end ?? total, total)
      guard offset < stop else { return }
      let count = min(want, stop - offset)
      switch source {
      case let .partial(body):
        guard let data = read(body, offset: offset, count: count) else {
          // The body moves when the download finishes; a later wait finds the finished file.
          try await Task.sleep(for: .milliseconds(50))
          continue
        }
        respond(data); offset += count
      case let .complete(file):
        guard let data = read(file, offset: offset, count: count) else { throw CocoaError(.fileReadUnknown) }
        respond(data); offset += count
      }
    }
  }

  private static func read(_ file: URL, offset: UInt64, count: UInt64) -> Data? {
    guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
    defer { try? handle.close() }
    guard (try? handle.seek(toOffset: offset)) != nil,
          let data = try? handle.read(upToCount: Int(count)), data.count == Int(count)
    else { return nil }
    return data
  }
}

/// A loading request answered from the stream's tasks rather than the delegate queue, which
/// AVFoundation accepts in practice.
private struct LoadingRequest: @unchecked Sendable {
  let request: AVAssetResourceLoadingRequest
  init(_ request: AVAssetResourceLoadingRequest) { self.request = request }
}
