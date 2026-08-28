import AppKit
import Auth
import Foundation
import ImageIO
import InlineKit

public struct DraftAttachmentImportSummary: Sendable {
  public let importedCount: Int
  public let ignoredCount: Int
  public let failures: [String]

  public var failedCount: Int {
    failures.count
  }

}

@MainActor
protocol DraftAttachmentWriting: AnyObject {
  @discardableResult
  func addImage(
    peer: Peer,
    image: PlatformImage,
    preferredFormat: ImageFormat?,
    onComplete: Drafts2AttachmentCompletion?
  ) -> String

  @discardableResult
  func addVideo(
    peer: Peer,
    url: URL,
    thumbnail: PlatformImage?,
    onComplete: Drafts2AttachmentCompletion?
  ) -> String

  @discardableResult
  func addAnimatedImage(
    peer: Peer,
    url: URL,
    onComplete: Drafts2AttachmentCompletion?
  ) -> String

  @discardableResult
  func addFile(
    peer: Peer,
    url: URL,
    onComplete: Drafts2AttachmentCompletion?
  ) -> String
}

extension Drafts2: DraftAttachmentWriting {}

@MainActor
public enum DraftAttachmentImporter {
  public static func `import`(
    _ attachments: [PasteboardAttachment],
    into peer: Peer,
    drafts: Drafts2 = .shared
  ) async -> DraftAttachmentImportSummary {
    guard let mutationToken = try? Auth.shared.handle.beginAccountMutation() else {
      return DraftAttachmentImportSummary(importedCount: 0, ignoredCount: 0, failures: [])
    }
    return await importAttachments(
      attachments,
      into: peer,
      writer: drafts,
      mutationToken: mutationToken
    )
  }

  public static func `import`(
    _ attachments: [PreparedPasteboardAttachment],
    into peer: Peer,
    drafts: Drafts2 = .shared
  ) async -> DraftAttachmentImportSummary {
    guard let mutationToken = try? Auth.shared.handle.beginAccountMutation() else {
      return DraftAttachmentImportSummary(importedCount: 0, ignoredCount: 0, failures: [])
    }
    return await importPreparedAttachments(
      attachments,
      into: peer,
      writer: drafts,
      mutationToken: mutationToken
    )
  }

  static func importPreparedAttachments(
    _ attachments: [PreparedPasteboardAttachment],
    into peer: Peer,
    writer: any DraftAttachmentWriting,
    mutationToken: AuthAccountMutationToken? = nil
  ) async -> DraftAttachmentImportSummary {
    var importedCount = 0
    var ignoredCount = 0
    var failures: [String] = []

    for attachment in attachments {
      guard !Task.isCancelled, mutationAllowed(mutationToken) else { break }
      switch await importPreparedAttachment(
        attachment,
        into: peer,
        writer: writer,
        mutationToken: mutationToken
      ) {
      case .imported:
        importedCount += 1
      case .ignored:
        ignoredCount += 1
      case let .failed(message):
        failures.append(message)
      }
    }

    return DraftAttachmentImportSummary(
      importedCount: importedCount,
      ignoredCount: ignoredCount,
      failures: failures
    )
  }

  static func importAttachments(
    _ attachments: [PasteboardAttachment],
    into peer: Peer,
    writer: any DraftAttachmentWriting,
    mutationToken: AuthAccountMutationToken? = nil
  ) async -> DraftAttachmentImportSummary {
    var importedCount = 0
    var ignoredCount = 0
    var failures: [String] = []

    for attachment in attachments {
      guard !Task.isCancelled, mutationAllowed(mutationToken) else { break }
      switch await importAttachment(
        attachment,
        into: peer,
        writer: writer,
        mutationToken: mutationToken
      ) {
      case .imported:
        importedCount += 1
      case .ignored:
        ignoredCount += 1
      case let .failed(message):
        failures.append(message)
      }
    }

    return DraftAttachmentImportSummary(
      importedCount: importedCount,
      ignoredCount: ignoredCount,
      failures: failures
    )
  }

  private enum Outcome {
    case imported
    case ignored
    case failed(String)
  }

  private struct SendableCGImage: @unchecked Sendable {
    let value: CGImage
  }

  private static func importPreparedAttachment(
    _ attachment: PreparedPasteboardAttachment,
    into peer: Peer,
    writer: any DraftAttachmentWriting,
    mutationToken: AuthAccountMutationToken?
  ) async -> Outcome {
    guard !Task.isCancelled, mutationAllowed(mutationToken) else { return .ignored }
    switch attachment {
    case let .imageFile(url):
      let decoded = await Task.detached(priority: .userInitiated) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil as SendableCGImage? }
        return SendableCGImage(value: image)
      }.value
      guard !Task.isCancelled, mutationAllowed(mutationToken) else { return .ignored }
      guard let decoded else {
        return outcome(from: await importFile(
          url,
          peer: peer,
          writer: writer,
          mutationToken: mutationToken
        ))
      }
      let image = NSImage(cgImage: decoded.value, size: .zero)
      let preferredFormat: ImageFormat? = url.pathExtension.lowercased() == "png" ? .png : nil
      let result = await awaitResult(mutationToken: mutationToken) { completion in
        _ = writer.addImage(
          peer: peer,
          image: image,
          preferredFormat: preferredFormat,
          onComplete: completion
        )
      }
      return await outcome(
        from: result,
        fallbackURL: url,
        peer: peer,
        writer: writer,
        mutationToken: mutationToken
      )

    case let .animatedImage(url):
      let result = await awaitResult(mutationToken: mutationToken) { completion in
        _ = writer.addAnimatedImage(peer: peer, url: url, onComplete: completion)
      }
      return await outcome(
        from: result,
        fallbackURL: url,
        peer: peer,
        writer: writer,
        mutationToken: mutationToken
      )

    case let .video(url):
      let result = await awaitResult(mutationToken: mutationToken) { completion in
        _ = writer.addVideo(peer: peer, url: url, thumbnail: nil, onComplete: completion)
      }
      return await outcome(
        from: result,
        fallbackURL: url,
        peer: peer,
        writer: writer,
        mutationToken: mutationToken
      )

    case let .file(url):
      guard !isDirectory(url) else {
        return .failed("Folders aren't supported yet.")
      }
      return outcome(from: await importFile(
        url,
        peer: peer,
        writer: writer,
        mutationToken: mutationToken
      ))

    case .text:
      return .ignored
    }
  }

  private static func importAttachment(
    _ attachment: PasteboardAttachment,
    into peer: Peer,
    writer: any DraftAttachmentWriting,
    mutationToken: AuthAccountMutationToken?
  ) async -> Outcome {
    guard !Task.isCancelled, mutationAllowed(mutationToken) else { return .ignored }
    switch attachment {
    case let .image(image, sourceURL):
      let preferredFormat: ImageFormat? = sourceURL?.pathExtension.lowercased() == "png" ? .png : nil
      let result = await awaitResult(mutationToken: mutationToken) { completion in
        _ = writer.addImage(
          peer: peer,
          image: image,
          preferredFormat: preferredFormat,
          onComplete: completion
        )
      }
      return await outcome(
        from: result,
        fallbackURL: sourceURL,
        peer: peer,
        writer: writer,
        mutationToken: mutationToken
      )

    case let .animatedImage(url):
      let result = await awaitResult(mutationToken: mutationToken) { completion in
        _ = writer.addAnimatedImage(
          peer: peer,
          url: url,
          onComplete: completion
        )
      }
      return await outcome(
        from: result,
        fallbackURL: url,
        peer: peer,
        writer: writer,
        mutationToken: mutationToken
      )

    case let .video(url, thumbnail):
      let result = await awaitResult(mutationToken: mutationToken) { completion in
        _ = writer.addVideo(
          peer: peer,
          url: url,
          thumbnail: thumbnail,
          onComplete: completion
        )
      }
      return await outcome(
        from: result,
        fallbackURL: url,
        peer: peer,
        writer: writer,
        mutationToken: mutationToken
      )

    case let .file(url, _):
      guard !isDirectory(url) else {
        return .failed("Folders aren't supported yet.")
      }
      return outcome(from: await importFile(
        url,
        peer: peer,
        writer: writer,
        mutationToken: mutationToken
      ))

    case .text:
      return .ignored
    }
  }

  private static func outcome(
    from result: Drafts2AttachmentResult,
    fallbackURL: URL?,
    peer: Peer,
    writer: any DraftAttachmentWriting,
    mutationToken: AuthAccountMutationToken?
  ) async -> Outcome {
    switch result {
    case .pending:
      return .failed("Attachment preparation did not finish.")
    case .success:
      return .imported
    case let .failure(_, originalMessage):
      guard let fallbackURL, !isDirectory(fallbackURL) else {
        return .failed(originalMessage)
      }

      let fallbackResult = await importFile(
        fallbackURL,
        peer: peer,
        writer: writer,
        mutationToken: mutationToken
      )
      switch fallbackResult {
      case .success:
        return .imported
      case let .failure(_, fallbackMessage):
        return .failed(fallbackMessage)
      case .pending:
        return .failed("Attachment preparation did not finish.")
      case .cancelled:
        return .failed("Attachment preparation was cancelled.")
      }
    case .cancelled:
      return .failed("Attachment preparation was cancelled.")
    }
  }

  private static func outcome(from result: Drafts2AttachmentResult) -> Outcome {
    switch result {
    case .pending:
      .failed("Attachment preparation did not finish.")
    case .success:
      .imported
    case let .failure(_, message):
      .failed(message)
    case .cancelled:
      .failed("Attachment preparation was cancelled.")
    }
  }

  private static func importFile(
    _ url: URL,
    peer: Peer,
    writer: any DraftAttachmentWriting,
    mutationToken: AuthAccountMutationToken?
  ) async -> Drafts2AttachmentResult {
    await awaitResult(mutationToken: mutationToken) { completion in
      _ = writer.addFile(
        peer: peer,
        url: url,
        onComplete: completion
      )
    }
  }

  private static func awaitResult(
    mutationToken: AuthAccountMutationToken?,
    _ operation: (@escaping Drafts2AttachmentCompletion) -> Void
  ) async -> Drafts2AttachmentResult {
    guard !Task.isCancelled, mutationAllowed(mutationToken) else {
      return .cancelled(pendingId: "cancelled_before_admission")
    }
    return await withCheckedContinuation { continuation in
      operation { result in
        continuation.resume(returning: result)
      }
    }
  }

  private static func mutationAllowed(_ token: AuthAccountMutationToken?) -> Bool {
    guard let token else { return !Task.isCancelled }
    do {
      try Auth.shared.handle.validateAccountMutation(token)
      return !Task.isCancelled
    } catch {
      return false
    }
  }

  private static func isDirectory(_ url: URL) -> Bool {
    (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
  }
}
