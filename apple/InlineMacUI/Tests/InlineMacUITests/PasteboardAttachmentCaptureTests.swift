import AppKit
import Foundation
import Testing

@testable import InlineMacUI

@MainActor
@Suite("Pasteboard attachment capture")
struct PasteboardAttachmentCaptureTests {
  @Test("file URLs stay immutable and are not copied during capture")
  func fileURLCapture() async throws {
    let sourceURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
      .appendingPathExtension("png")
    try onePixelPNGData().write(to: sourceURL)
    defer { try? FileManager.default.removeItem(at: sourceURL) }

    let capture = InlinePasteboard.captureAttachments(
      from: makePasteboard(type: .fileURL, string: sourceURL.absoluteString),
      includeText: false
    )
    #expect(capture.potentialAttachmentCount == 1)
    #expect(capture.failures.isEmpty)

    let result = await capture.materialize()
    defer { result.cleanup() }
    guard case let .imageFile(url)? = result.attachments.first else {
      Issue.record("Expected a deferred image-file attachment")
      return
    }
    #expect(url == sourceURL)

    result.cleanup()
    #expect(FileManager.default.fileExists(atPath: sourceURL.path))
  }

  @Test("raw data is staged off the capture path and cleaned exactly once")
  func rawDataCleanup() async throws {
    let sourceView = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
    let capture = InlinePasteboard.captureAttachments(
      from: makePasteboard(type: .pdf, data: sourceView.dataWithPDF(inside: sourceView.bounds)),
      includeText: false
    )

    let result = await capture.materialize()
    guard case let .file(url)? = result.attachments.first else {
      Issue.record("Expected a prepared PDF attachment")
      return
    }
    #expect(url.pathExtension == "pdf")
    #expect(FileManager.default.fileExists(atPath: url.path))

    result.cleanup()
    result.cleanup()
    #expect(!FileManager.default.fileExists(atPath: url.path))
  }

  @Test("directories are rejected without a materialization job")
  func directoryCapture() async {
    let capture = InlinePasteboard.captureAttachments(
      from: makePasteboard(
        type: .fileURL,
        string: FileManager.default.temporaryDirectory.absoluteString
      ),
      includeText: false
    )

    #expect(capture.potentialAttachmentCount == 0)
    #expect(capture.failures.first?.isDirectory == true)
    let result = await capture.materialize()
    defer { result.cleanup() }
    #expect(result.attachments.isEmpty)
    #expect(result.failures.first?.isDirectory == true)
  }

  @Test("invalid raw image data is rejected instead of attached as a document")
  func invalidRawImage() async {
    let capture = InlinePasteboard.captureAttachments(
      from: makePasteboard(type: .png, data: Data("not an image".utf8)),
      includeText: false
    )

    let result = await capture.materialize()
    defer { result.cleanup() }
    #expect(result.attachments.isEmpty)
    #expect(result.failures == [.materializationFailed])
  }

  @Test("a captured pasteboard can only be materialized once")
  func captureIsSingleUse() async {
    let capture = InlinePasteboard.captureAttachments(
      from: makePasteboard(type: .pdf, data: Data("pdf".utf8)),
      includeText: false
    )

    let first = await capture.materialize()
    defer { first.cleanup() }
    let second = await capture.materialize()
    defer { second.cleanup() }

    #expect(first.attachments.count == 1)
    #expect(second.attachments.isEmpty)
    #expect(second.failures.contains(.materializationFailed))
  }

  @Test("file promises materialize into job-owned storage and clean up")
  func filePromiseCapture() async throws {
    let resources = PasteboardAttachmentResources()
    let directory = try resources.makeTemporaryDirectory(prefix: "inline-file-promise-test")
    let url = directory.appendingPathComponent("promised.txt")
    try Data("promised".utf8).write(to: url)
    let capture = PasteboardAttachmentCapture(
      payloads: [.filePromise(TestFilePromise(url: url))],
      captureFailures: [],
      resources: resources
    )
    #expect(capture.potentialAttachmentCount == 1)
    let result = await capture.materialize()
    guard case let .file(url)? = result.attachments.first else {
      Issue.record("Expected a materialized promised file")
      return
    }
    #expect(url.lastPathComponent == "promised.txt")
    #expect(try Data(contentsOf: url) == Data("promised".utf8))

    result.cleanup()
    #expect(!FileManager.default.fileExists(atPath: url.path))
  }

  private func makePasteboard(
    type: NSPasteboard.PasteboardType,
    string: String
  ) -> NSPasteboard {
    let item = NSPasteboardItem()
    item.setString(string, forType: type)
    return makePasteboard(item: item)
  }

  private func makePasteboard(
    type: NSPasteboard.PasteboardType,
    data: Data
  ) -> NSPasteboard {
    let item = NSPasteboardItem()
    item.setData(data, forType: type)
    return makePasteboard(item: item)
  }

  private func makePasteboard(item: NSPasteboardItem) -> NSPasteboard {
    let pasteboard = NSPasteboard.withUniqueName()
    pasteboard.clearContents()
    pasteboard.writeObjects([item])
    return pasteboard
  }

  private func onePixelPNGData() throws -> Data {
    try #require(Data(base64Encoded:
      "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
    ))
  }
}

private struct TestFilePromise: PasteboardFilePromiseMaterializing {
  let url: URL

  func materialize() async -> PasteboardPromisedFiles {
    PasteboardPromisedFiles(urls: [url], failureCount: 0)
  }
}
