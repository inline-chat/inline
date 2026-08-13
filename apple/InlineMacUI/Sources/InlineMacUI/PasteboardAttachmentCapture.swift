import AppKit
import Foundation
import ImageIO

/// Immutable pasteboard contents captured while AppKit still owns the drag.
/// Expensive decoding and temporary-file writes happen later, off the main
/// actor, without retaining `NSPasteboard` or reusable row state.
public struct PasteboardAttachmentCapture: Sendable {
  enum Payload: Sendable {
    case fileURL(URL)
    case filePromise(any PasteboardFilePromiseMaterializing)
    case data(Data, type: String)
    case text(String)
  }

  private let payloads: [Payload]
  private let captureFailures: [PasteboardAttachmentFailure]
  private let resources: PasteboardAttachmentResources

  init(
    payloads: [Payload],
    captureFailures: [PasteboardAttachmentFailure],
    resources: PasteboardAttachmentResources
  ) {
    self.payloads = payloads
    self.captureFailures = captureFailures
    self.resources = resources
  }

  public var potentialAttachmentCount: Int {
    payloads.count
  }

  public var failures: [PasteboardAttachmentFailure] {
    captureFailures
  }

  public func materialize() async -> PreparedPasteboardAttachmentResult {
    let payloads = payloads
    let captureFailures = captureFailures
    let resources = resources

    guard resources.claimMaterialization() else {
      return PreparedPasteboardAttachmentResult(
        attachments: [],
        failures: captureFailures + [.materializationFailed],
        cleanup: resources.cleanup
      )
    }

    return await Task.detached(priority: .userInitiated) {
      var attachments: [PreparedPasteboardAttachment] = []
      var failures = captureFailures

      for payload in payloads {
        switch payload {
        case let .fileURL(url):
          if let attachment = Self.attachment(for: url) {
            attachments.append(attachment)
          }

        case let .filePromise(promise):
          let promisedFiles = await promise.materialize()
          for url in promisedFiles.urls {
            if let attachment = Self.attachment(for: url) {
              attachments.append(attachment)
            } else {
              failures.append(.materializationFailed)
            }
          }
          failures.append(contentsOf: repeatElement(
            .materializationFailed,
            count: promisedFiles.failureCount
          ))

        case let .data(data, rawType):
          let type = NSPasteboard.PasteboardType(rawType)
          do {
            let url = try Self.createTemporaryFile(
              data: data,
              fileExtension: InlinePasteboard.fileExtension(for: type)
            )
            resources.retainTemporaryFile(url)
            if let attachment = Self.attachment(for: url, representedType: type) {
              attachments.append(attachment)
            } else {
              failures.append(.materializationFailed)
            }
          } catch {
            failures.append(.materializationFailed)
          }

        case let .text(text):
          attachments.append(.text(text))
        }
      }

      return PreparedPasteboardAttachmentResult(
        attachments: attachments,
        failures: failures,
        cleanup: resources.cleanup
      )
    }.value
  }

  private static func attachment(
    for url: URL,
    representedType: NSPasteboard.PasteboardType? = nil
  ) -> PreparedPasteboardAttachment? {
    let fileExtension = url.pathExtension.lowercased()
    if representedType.map(InlinePasteboard.isAnimatedImageType) == true || fileExtension == "gif" {
      return .animatedImage(url)
    }
    if representedType.map({ InlinePasteboard.preferredVideoTypes.contains($0) }) == true ||
      InlinePasteboard.isVideoFileExtension(fileExtension) {
      return .video(url)
    }
    if representedType.map({ InlinePasteboard.preferredImageTypes.contains($0) }) == true ||
      InlinePasteboard.isImageFileExtension(fileExtension) {
      if representedType != nil,
         (CGImageSourceCreateWithURL(url as CFURL, nil).flatMap {
           CGImageSourceCreateImageAtIndex($0, 0, nil)
         }) == nil {
        return nil
      }
      return .imageFile(url)
    }
    return .file(url)
  }

  private static func createTemporaryFile(
    data: Data,
    fileExtension: String
  ) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("inline-pasteboard-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    let url = directory
      .appendingPathComponent("attachment")
      .appendingPathExtension(fileExtension)
    do {
      try data.write(to: url, options: .atomic)
      return url
    } catch {
      try? FileManager.default.removeItem(at: directory)
      throw error
    }
  }
}

public enum PreparedPasteboardAttachment: Sendable {
  case imageFile(URL)
  case animatedImage(URL)
  case video(URL)
  case file(URL)
  case text(String)
}

public struct PreparedPasteboardAttachmentResult: Sendable {
  public let attachments: [PreparedPasteboardAttachment]
  public let failures: [PasteboardAttachmentFailure]
  private let cleanupHandler: @Sendable () -> Void

  fileprivate init(
    attachments: [PreparedPasteboardAttachment],
    failures: [PasteboardAttachmentFailure],
    cleanup: @escaping @Sendable () -> Void
  ) {
    self.attachments = attachments
    self.failures = failures
    cleanupHandler = cleanup
  }

  /// Releases captured sandbox access and removes raw-data staging files.
  /// Safe to call more than once.
  public func cleanup() {
    cleanupHandler()
  }
}

final class PasteboardAttachmentResources: @unchecked Sendable {
  private let lock = NSLock()
  private var securityScopedURLs: [URL]
  private var temporaryDirectories: Set<URL> = []
  private var isCleanedUp = false
  private var didBeginMaterialization = false

  init() {
    securityScopedURLs = []
  }

  deinit {
    cleanup()
  }

  func claimMaterialization() -> Bool {
    lock.withLock {
      guard !isCleanedUp, !didBeginMaterialization else { return false }
      didBeginMaterialization = true
      return true
    }
  }

  func retainTemporaryFile(_ url: URL) {
    lock.withLock {
      guard !isCleanedUp else { return }
      temporaryDirectories.insert(url.deletingLastPathComponent())
    }
  }

  func retainSecurityScopedFile(_ url: URL) {
    guard url.startAccessingSecurityScopedResource() else { return }
    let retained = lock.withLock {
      guard !isCleanedUp else { return false }
      securityScopedURLs.append(url)
      return true
    }
    if !retained {
      url.stopAccessingSecurityScopedResource()
    }
  }

  func makeTemporaryDirectory(prefix: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    let retained = lock.withLock {
      guard !isCleanedUp else { return false }
      temporaryDirectories.insert(directory)
      return true
    }
    guard retained else {
      try? FileManager.default.removeItem(at: directory)
      throw CancellationError()
    }
    return directory
  }

  func cleanup() {
    let owned: ([URL], [URL])? = lock.withLock {
      guard !isCleanedUp else { return nil }
      isCleanedUp = true
      let value = (securityScopedURLs, Array(temporaryDirectories))
      securityScopedURLs.removeAll()
      temporaryDirectories.removeAll()
      return value
    }
    guard let owned else { return }
    for url in owned.0 {
      url.stopAccessingSecurityScopedResource()
    }
    for directory in owned.1 {
      try? FileManager.default.removeItem(at: directory)
    }
  }
}

struct PasteboardPromisedFiles: Sendable {
  let urls: [URL]
  let failureCount: Int
}

protocol PasteboardFilePromiseMaterializing: Sendable {
  func materialize() async -> PasteboardPromisedFiles
}

final class PasteboardFilePromise: @unchecked Sendable {
  private let reception: PasteboardFilePromiseReception

  @MainActor
  init(
    receiver: NSFilePromiseReceiver,
    resources: PasteboardAttachmentResources
  ) throws {
    let destination = try resources.makeTemporaryDirectory(prefix: "inline-file-promise")
    let operationQueue = OperationQueue()
    operationQueue.qualityOfService = .userInitiated
    operationQueue.maxConcurrentOperationCount = 1
    reception = PasteboardFilePromiseReception()

    // AppKit requires this registration to happen synchronously inside
    // performDragOperation. The receiver may fulfill later on this queue.
    receiver.receivePromisedFiles(
      atDestination: destination,
      options: [:],
      operationQueue: operationQueue
    ) { [reception] url, error in
      reception.receive(url: url, error: error)
    }
    operationQueue.addBarrierBlock { [reception] in
      reception.finish()
    }
  }
}

extension PasteboardFilePromise: PasteboardFilePromiseMaterializing {
  func materialize() async -> PasteboardPromisedFiles {
    await reception.value()
  }
}

private final class PasteboardFilePromiseReception: @unchecked Sendable {
  private let lock = NSLock()
  private var urls: [URL] = []
  private var failureCount = 0
  private var result: PasteboardPromisedFiles?
  private var waiters: [CheckedContinuation<PasteboardPromisedFiles, Never>] = []

  func value() async -> PasteboardPromisedFiles {
    await withCheckedContinuation { continuation in
      let completed = lock.withLock {
        guard let result else {
          waiters.append(continuation)
          return nil as PasteboardPromisedFiles?
        }
        return result
      }
      if let completed {
        continuation.resume(returning: completed)
      }
    }
  }

  func receive(url: URL, error: Error?) {
    lock.withLock {
      if error == nil {
        urls.append(url)
      } else {
        failureCount += 1
      }
    }
  }

  func finish() {
    let completed: (PasteboardPromisedFiles, [CheckedContinuation<PasteboardPromisedFiles, Never>])? = lock.withLock {
      guard result == nil else { return nil }
      let completed = PasteboardPromisedFiles(urls: urls, failureCount: failureCount)
      result = completed
      let continuations = waiters
      waiters.removeAll()
      return (completed, continuations)
    }
    guard let completed else { return }
    for continuation in completed.1 {
      continuation.resume(returning: completed.0)
    }
  }
}

public extension InlinePasteboard {
  /// Capture the accepted drag synchronously, but avoid image decode and disk
  /// staging until `materialize()` runs away from the main actor.
  @MainActor
  static func captureAttachments(
    from pasteboard: NSPasteboard,
    includeText: Bool = true
  ) -> PasteboardAttachmentCapture {
    let decodedFileURLs = readFileURLs(from: pasteboard)
    var payloads: [PasteboardAttachmentCapture.Payload] = []
    var failures: [PasteboardAttachmentFailure] = []
    let resources = PasteboardAttachmentResources()

    for item in pasteboard.pasteboardItems ?? [] {
      let types = item.types
      var unreadableFileFailure: PasteboardAttachmentFailure?

      if types.contains(.fileURL),
         let value = item.string(forType: .fileURL),
         let url = resolveFileURL(value, decodedFileURLs: decodedFileURLs) {
        if let failure = fileURLFailure(url) {
          if failure.isDirectory {
            failures.append(failure)
            continue
          }
          unreadableFileFailure = failure
        } else {
          payloads.append(.fileURL(url))
          resources.retainSecurityScopedFile(url)
          continue
        }
      }

      if types.contains(.pdf), let data = item.data(forType: .pdf) {
        payloads.append(.data(data, type: NSPasteboard.PasteboardType.pdf.rawValue))
        continue
      }

      if let type = preferredVideoTypes.first(where: types.contains),
         let data = item.data(forType: type) {
        payloads.append(.data(data, type: type.rawValue))
        continue
      }

      if let type = preferredImageTypes.first(where: types.contains),
         let data = item.data(forType: type) {
        payloads.append(.data(data, type: type.rawValue))
        continue
      }

      if includeText, types.contains(.string), let text = item.string(forType: .string) {
        payloads.append(.text(text))
        continue
      }

      if let unreadableFileFailure {
        failures.append(unreadableFileFailure)
      }
    }

    let filePromises = pasteboard.readObjects(
      forClasses: [NSFilePromiseReceiver.self],
      options: nil
    ) as? [NSFilePromiseReceiver] ?? []
    for receiver in filePromises {
      do {
        payloads.append(.filePromise(try PasteboardFilePromise(
          receiver: receiver,
          resources: resources
        )))
      } catch {
        failures.append(.materializationFailed)
      }
    }

    return PasteboardAttachmentCapture(
      payloads: payloads,
      captureFailures: failures,
      resources: resources
    )
  }
}
