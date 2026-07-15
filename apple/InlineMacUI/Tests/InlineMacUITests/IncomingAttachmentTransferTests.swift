import AppKit
import CoreTransferable
import Foundation
import Testing
import UniformTypeIdentifiers

@testable import InlineMacUI

@MainActor
@Suite("Incoming attachment transfer")
struct IncomingAttachmentTransferTests {
  @Test("plain text is not a compatible attachment transfer")
  func plainTextIsExcluded() async {
    let provider = NSItemProvider(object: NSString(string: "hello"))
    let result = await load(provider)

    guard case .failure = result else {
      Issue.record("Expected plain text to be incompatible")
      return
    }
  }

  @Test("generic Finder files are durably staged from file URLs")
  func genericFileURLIsStaged() async throws {
    let sourceURL = try makeTemporaryFile(extension: "txt", data: Data("hello".utf8))
    defer { try? FileManager.default.removeItem(at: sourceURL) }
    let provider = try #require(NSItemProvider(contentsOf: sourceURL))

    let transfer = try await load(provider).get()
    defer { transfer.cleanup() }
    let stagedURL = try #require(stagedFileURL(from: transfer))

    #expect(stagedURL != sourceURL)
    #expect(stagedURL.pathExtension == "txt")
    #expect(try Data(contentsOf: stagedURL) == Data("hello".utf8))
  }

  @Test("raw images use a staged file representation")
  func rawImageIsStaged() async throws {
    let provider = dataProvider(type: .png, data: try onePixelPNGData())

    let transfer = try await load(provider).get()
    defer { transfer.cleanup() }
    let result = InlinePasteboard.findAttachmentsResult(from: [transfer])

    guard case .image? = result.attachments.first else {
      Issue.record("Expected an image attachment")
      return
    }
    #expect(result.failures.isEmpty)
  }

  @Test("raw GIFs preserve animated-image classification")
  func rawGIFIsStaged() async throws {
    let provider = dataProvider(
      type: .gif,
      data: Data("GIF89a".utf8)
    )

    let transfer = try await load(provider).get()
    defer { transfer.cleanup() }
    let result = InlinePasteboard.findAttachmentsResult(from: [transfer])

    guard case let .animatedImage(url)? = result.attachments.first else {
      Issue.record("Expected an animated-image attachment")
      return
    }
    #expect(url.pathExtension == "gif")
    #expect(result.failures.isEmpty)
  }

  @Test("unreadable file URLs fall through to raw image data")
  func unreadableFileURLFallsBackToImage() async throws {
    let missingURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
      .appendingPathExtension("png")
    let provider = NSItemProvider()
    provider.registerDataRepresentation(
      forTypeIdentifier: UTType.fileURL.identifier,
      visibility: .all
    ) { completion in
      completion(Data(missingURL.absoluteString.utf8), nil)
      return nil
    }
    registerData(try onePixelPNGData(), type: .png, with: provider)

    let transfer = try await load(provider).get()
    defer { transfer.cleanup() }
    let result = InlinePasteboard.findAttachmentsResult(from: [transfer])

    guard case .image? = result.attachments.first else {
      Issue.record("Expected raw image fallback")
      return
    }
    #expect(result.failures.isEmpty)
  }

  @Test("raw videos remain typed video attachments")
  func rawVideoIsStaged() async throws {
    let provider = dataProvider(
      type: .mpeg4Movie,
      data: Data([0, 0, 0, 0])
    )

    let transfer = try await load(provider).get()
    defer { transfer.cleanup() }
    let result = InlinePasteboard.findAttachmentsResult(from: [transfer])

    guard case let .video(url, _)? = result.attachments.first else {
      Issue.record("Expected a video attachment")
      return
    }
    #expect(url.pathExtension == "mp4")
    #expect(result.failures.isEmpty)
  }

  @Test("folders become explicit rejected transfers")
  func folderIsRejected() async throws {
    let provider = try #require(NSItemProvider(contentsOf: FileManager.default.temporaryDirectory))

    let transfer = try await load(provider).get()
    let result = InlinePasteboard.findAttachmentsResult(from: [transfer])

    #expect(result.attachments.isEmpty)
    #expect(result.failures.count == 1)
    #expect(result.failures.first?.isDirectory == true)
  }

  @Test("file representations are copied before provider access expires")
  func promisedPDFIsStaged() async throws {
    let sourceView = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
    let sourceURL = try makeTemporaryFile(
      extension: "pdf",
      data: sourceView.dataWithPDF(inside: sourceView.bounds)
    )
    defer { try? FileManager.default.removeItem(at: sourceURL) }
    let provider = NSItemProvider()
    provider.registerFileRepresentation(
      forTypeIdentifier: UTType.pdf.identifier,
      fileOptions: [],
      visibility: .all
    ) { completion in
      completion(sourceURL, false, nil)
      return nil
    }

    let transfer = try await load(provider).get()
    let stagedURL = try #require(stagedFileURL(from: transfer))
    defer { transfer.cleanup() }

    #expect(stagedURL != sourceURL)
    #expect(stagedURL.pathExtension == "pdf")
    #expect(FileManager.default.fileExists(atPath: stagedURL.path))
  }

  @Test("mixed transfers preserve valid items and folder failures")
  func mixedTransfersPreservePartialResults() async throws {
    let fileURL = try makeTemporaryFile(extension: "txt", data: Data("hello".utf8))
    defer { try? FileManager.default.removeItem(at: fileURL) }
    let fileProvider = try #require(NSItemProvider(contentsOf: fileURL))
    let folderProvider = try #require(NSItemProvider(contentsOf: FileManager.default.temporaryDirectory))

    let fileTransfer = try await load(fileProvider).get()
    let folderTransfer = try await load(folderProvider).get()
    let transfers = [fileTransfer, folderTransfer]
    defer { transfers.forEach { $0.cleanup() } }
    let result = InlinePasteboard.findAttachmentsResult(from: transfers)

    #expect(result.attachments.count == 1)
    #expect(result.failures.count == 1)
    #expect(result.failures.first?.isDirectory == true)
  }

  private func load(
    _ provider: NSItemProvider
  ) async -> Result<IncomingAttachmentTransfer, Error> {
    await withCheckedContinuation { continuation in
      _ = provider.loadTransferable(type: IncomingAttachmentTransfer.self) { result in
        continuation.resume(returning: result)
      }
    }
  }

  private func stagedFileURL(from transfer: IncomingAttachmentTransfer) -> URL? {
    guard case let .stagedFile(url, _) = transfer.payload else { return nil }
    return url
  }

  private func dataProvider(type: UTType, data: Data) -> NSItemProvider {
    let provider = NSItemProvider()
    registerData(data, type: type, with: provider)
    return provider
  }

  private func registerData(_ data: Data, type: UTType, with provider: NSItemProvider) {
    provider.registerDataRepresentation(
      forTypeIdentifier: type.identifier,
      visibility: .all
    ) { completion in
      completion(data, nil)
      return nil
    }
  }

  private func makeTemporaryFile(extension value: String, data: Data) throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
      .appendingPathExtension(value)
    try data.write(to: url)
    return url
  }

  private func onePixelPNGData() throws -> Data {
    try #require(Data(base64Encoded:
      "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
    ))
  }
}
