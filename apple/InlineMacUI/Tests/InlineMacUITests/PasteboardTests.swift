import AppKit
import Foundation
import Testing

@testable import InlineMacUI

@MainActor
@Suite("Inline pasteboard")
struct PasteboardTests {
  @Test("directory file URLs are rejected")
  func directoryFileURLsAreRejected() {
    let pasteboard = makePasteboard(
      type: .fileURL,
      string: FileManager.default.temporaryDirectory.absoluteString
    )

    let result = InlinePasteboard.findAttachmentsResult(
      from: pasteboard,
      includeText: false
    )

    #expect(result.attachments.isEmpty)
    #expect(result.failures.count == 1)
    #expect(result.failures.first?.isDirectory == true)
    #expect(!InlinePasteboard.canImportAttachments(from: pasteboard, includeText: false))
  }

  @Test("directory file URLs stay rejected when an image representation is present")
  func directoryWithImageRepresentationIsRejected() throws {
    let item = NSPasteboardItem()
    item.setString(FileManager.default.temporaryDirectory.absoluteString, forType: .fileURL)
    item.setData(try onePixelPNGData(), forType: .png)
    let pasteboard = makePasteboard(item: item)

    let result = InlinePasteboard.findAttachmentsResult(
      from: pasteboard,
      includeText: false
    )

    #expect(result.attachments.isEmpty)
    #expect(result.failures.count == 1)
    #expect(result.failures.first?.isDirectory == true)
    #expect(!InlinePasteboard.canImportAttachments(from: pasteboard, includeText: false))
  }

  @Test("raw GIF data becomes an animated image attachment")
  func rawGIFBecomesAnimatedImage() throws {
    let type = NSPasteboard.PasteboardType("public.gif")
    let pasteboard = makePasteboard(
      type: type,
      data: Data("GIF89a".utf8)
    )

    let result = InlinePasteboard.findAttachmentsResult(
      from: pasteboard,
      includeText: false
    )
    guard case let .animatedImage(url)? = result.attachments.first else {
      Issue.record("Expected an animated image attachment")
      return
    }
    defer { try? FileManager.default.removeItem(at: url) }

    #expect(url.pathExtension == "gif")
    #expect(result.failures.isEmpty)
  }

  @Test("raw GIF data replaces an unreadable transient file URL")
  func rawGIFFallsBackFromUnreadableFileURL() throws {
    let inaccessibleURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
      .appendingPathExtension("gif")
    let item = NSPasteboardItem()
    item.setString(inaccessibleURL.absoluteString, forType: .fileURL)
    item.setData(Data("GIF89a".utf8), forType: NSPasteboard.PasteboardType("public.gif"))
    let pasteboard = makePasteboard(item: item)

    let result = InlinePasteboard.findAttachmentsResult(
      from: pasteboard,
      includeText: false
    )
    guard case let .animatedImage(url)? = result.attachments.first else {
      Issue.record("Expected an animated image attachment")
      return
    }
    defer { try? FileManager.default.removeItem(at: url) }

    #expect(url != inaccessibleURL)
    #expect(FileManager.default.fileExists(atPath: url.path))
    #expect(result.failures.isEmpty)
  }

  @Test("raw image data replaces an unreadable transient file URL")
  func rawImageFallsBackFromUnreadableFileURL() throws {
    let inaccessibleURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
      .appendingPathExtension("png")
    let item = NSPasteboardItem()
    item.setString(inaccessibleURL.absoluteString, forType: .fileURL)
    item.setData(try onePixelPNGData(), forType: .png)
    let pasteboard = makePasteboard(item: item)

    let result = InlinePasteboard.findAttachmentsResult(
      from: pasteboard,
      includeText: false
    )
    guard case let .image(_, sourceURL)? = result.attachments.first else {
      Issue.record("Expected an image attachment")
      return
    }

    #expect(sourceURL == nil)
    #expect(result.failures.isEmpty)
  }

  @Test("raw video data becomes a typed temporary video")
  func rawVideoBecomesVideoAttachment() throws {
    let type = NSPasteboard.PasteboardType("public.mpeg-4")
    let pasteboard = makePasteboard(
      type: type,
      data: Data([0, 0, 0, 0])
    )

    let result = InlinePasteboard.findAttachmentsResult(
      from: pasteboard,
      includeText: false
    )
    guard case let .video(url, _)? = result.attachments.first else {
      Issue.record("Expected a video attachment")
      return
    }
    defer { try? FileManager.default.removeItem(at: url) }

    #expect(url.pathExtension == "mp4")
    #expect(result.failures.isEmpty)
  }

  @Test("raw PDF data becomes a temporary document")
  func rawPDFBecomesDocumentAttachment() throws {
    let sourceView = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
    let pasteboard = makePasteboard(
      type: .pdf,
      data: sourceView.dataWithPDF(inside: sourceView.bounds)
    )

    let result = InlinePasteboard.findAttachmentsResult(
      from: pasteboard,
      includeText: false
    )
    guard case let .file(url, _)? = result.attachments.first else {
      Issue.record("Expected a PDF document attachment")
      return
    }
    defer { try? FileManager.default.removeItem(at: url) }

    #expect(url.pathExtension == "pdf")
    #expect(FileManager.default.fileExists(atPath: url.path))
    #expect(result.failures.isEmpty)
  }

  @Test("generic readable files remain document attachments")
  func genericFileBecomesDocumentAttachment() throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
      .appendingPathExtension("txt")
    try Data("hello".utf8).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }

    let pasteboard = makePasteboard(
      type: .fileURL,
      string: url.absoluteString
    )
    let result = InlinePasteboard.findAttachmentsResult(
      from: pasteboard,
      includeText: false
    )

    guard case let .file(attachmentURL, _)? = result.attachments.first else {
      Issue.record("Expected a file attachment")
      return
    }
    #expect(attachmentURL == url)
    #expect(result.failures.isEmpty)
    #expect(InlinePasteboard.canImportAttachments(from: pasteboard, includeText: false))
  }

  @Test("plain text is excluded from attachment-only drops")
  func textIsExcluded() {
    let pasteboard = makePasteboard(type: .string, string: "hello")

    let result = InlinePasteboard.findAttachmentsResult(
      from: pasteboard,
      includeText: false
    )

    #expect(result.attachments.isEmpty)
    #expect(!InlinePasteboard.canImportAttachments(from: pasteboard, includeText: false))
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
