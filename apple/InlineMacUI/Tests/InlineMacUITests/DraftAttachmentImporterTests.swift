import AppKit
import Foundation
import InlineKit
import Testing

@testable import InlineMacUI

@MainActor
@Suite("Draft attachment importer")
struct DraftAttachmentImporterTests {
  @Test("routes every supported attachment to the requested peer")
  func routesSupportedAttachmentsToPeer() async {
    let writer = FakeDraftAttachmentWriter()
    let peer = Peer.thread(id: 42)
    let url = URL(fileURLWithPath: "/tmp/attachment.dat")
    let attachments: [PasteboardAttachment] = [
      .image(NSImage(size: NSSize(width: 10, height: 10)), nil),
      .animatedImage(url),
      .video(url, thumbnail: nil),
      .file(url, thumbnail: nil),
    ]

    let summary = await DraftAttachmentImporter.importAttachments(
      attachments,
      into: peer,
      writer: writer
    )

    #expect(summary.importedCount == 4)
    #expect(summary.failedCount == 0)
    #expect(Set(writer.calls.map(\.kind)) == Set(FakeDraftAttachmentWriter.Kind.allCases))
    #expect(writer.calls.allSatisfy { $0.peer == peer })
  }

  @Test("rejects directories before calling the draft writer")
  func rejectsDirectories() async {
    let writer = FakeDraftAttachmentWriter()

    let summary = await DraftAttachmentImporter.importAttachments(
      [.file(FileManager.default.temporaryDirectory, thumbnail: nil)],
      into: .user(id: 7),
      writer: writer
    )

    #expect(summary.importedCount == 0)
    #expect(summary.failedCount == 1)
    #expect(writer.calls.isEmpty)
  }

  @Test("keeps consecutive imports scoped to their destination peers")
  func keepsImportsPeerScoped() async {
    let writer = FakeDraftAttachmentWriter()
    let firstPeer = Peer.thread(id: 42)
    let secondPeer = Peer.user(id: 7)

    let firstSummary = await DraftAttachmentImporter.importAttachments(
      [.file(URL(fileURLWithPath: "/tmp/first.dat"), thumbnail: nil)],
      into: firstPeer,
      writer: writer
    )
    let secondSummary = await DraftAttachmentImporter.importAttachments(
      [.file(URL(fileURLWithPath: "/tmp/second.dat"), thumbnail: nil)],
      into: secondPeer,
      writer: writer
    )

    #expect(firstSummary.importedCount == 1)
    #expect(secondSummary.importedCount == 1)
    #expect(writer.calls.map(\.peer) == [firstPeer, secondPeer])
  }

  @Test("falls back to a document when GIF conversion fails")
  func animatedImageFallsBackToDocument() async {
    let writer = FakeDraftAttachmentWriter(failingKinds: [.animatedImage])
    let url = URL(fileURLWithPath: "/tmp/animation.gif")

    let summary = await DraftAttachmentImporter.importAttachments(
      [.animatedImage(url)],
      into: .user(id: 8),
      writer: writer
    )

    #expect(summary.importedCount == 1)
    #expect(summary.failedCount == 0)
    #expect(writer.calls.map(\.kind) == [.animatedImage, .file])
  }

  @Test("ignores text payloads")
  func ignoresText() async {
    let writer = FakeDraftAttachmentWriter()

    let summary = await DraftAttachmentImporter.importAttachments(
      [.text("hello")],
      into: .user(id: 9),
      writer: writer
    )

    #expect(summary.importedCount == 0)
    #expect(summary.ignoredCount == 1)
    #expect(writer.calls.isEmpty)
  }
}

@MainActor
private final class FakeDraftAttachmentWriter: DraftAttachmentWriting {
  enum Kind: CaseIterable, Hashable {
    case image
    case animatedImage
    case video
    case file
  }

  struct Call {
    let kind: Kind
    let peer: Peer
  }

  private let failingKinds: Set<Kind>
  private(set) var calls: [Call] = []

  init(failingKinds: Set<Kind> = []) {
    self.failingKinds = failingKinds
  }

  func addImage(
    peer: Peer,
    image: PlatformImage,
    preferredFormat: ImageFormat?,
    onComplete: Drafts2AttachmentCompletion?
  ) -> String {
    complete(.image, peer: peer, onComplete: onComplete)
  }

  func addVideo(
    peer: Peer,
    url: URL,
    thumbnail: PlatformImage?,
    onComplete: Drafts2AttachmentCompletion?
  ) -> String {
    complete(.video, peer: peer, onComplete: onComplete)
  }

  func addAnimatedImage(
    peer: Peer,
    url: URL,
    onComplete: Drafts2AttachmentCompletion?
  ) -> String {
    complete(.animatedImage, peer: peer, onComplete: onComplete)
  }

  func addFile(
    peer: Peer,
    url: URL,
    onComplete: Drafts2AttachmentCompletion?
  ) -> String {
    complete(.file, peer: peer, onComplete: onComplete)
  }

  private func complete(
    _ kind: Kind,
    peer: Peer,
    onComplete: Drafts2AttachmentCompletion?
  ) -> String {
    let pendingID = "pending-\(calls.count)"
    calls.append(Call(kind: kind, peer: peer))

    if failingKinds.contains(kind) {
      onComplete?(.failure(pendingId: pendingID, message: "failed"))
    } else {
      onComplete?(.success(
        pendingId: pendingID,
        attachment: Drafts2Attachment(
          id: "attachment-\(calls.count)",
          media: .voice(.init())
        )
      ))
    }

    return pendingID
  }
}
