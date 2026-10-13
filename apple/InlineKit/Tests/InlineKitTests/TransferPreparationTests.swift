import Foundation
import Testing
import InlineProtocol
import GRDB
@testable import Auth
@testable import InlineKit

@Suite("Transfer preparation deadlines")
struct TransferPreparationTests {
  @Test("a stalled operation is canceled by its preparation deadline")
  func stalledPreparation() async {
    do {
      _ = try await TransferPreparation.withDeadline(seconds: 0.01, cancel: {}) {
        try await Task.sleep(for: .seconds(30))
        return 1
      }
      Issue.record("Expected preparation timeout")
    } catch TransferPreparationError.timedOut {} catch { Issue.record("Unexpected error: \(error)") }
  }

  @Test("successful preparation cancels its timer")
  func successfulPreparation() async throws {
    let value = try await TransferPreparation.withDeadline(seconds: 30, cancel: {}) { 42 }
    #expect(value == 42)
  }

  @Test("attach-time size error states the decimal 500 MB limit", arguments: [500_000_000, 500_000_001])
  func attachmentBoundary(bytes: Int) throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    FileManager.default.createFile(atPath: url.path, contents: nil)
    defer { try? FileManager.default.removeItem(at: url) }
    let handle = try FileHandle(forWritingTo: url)
    try handle.truncate(atOffset: UInt64(bytes))
    try handle.close()
    for kind in [InlineProtocol.UploadKind.document, .video] {
      do {
        try MediaUploadLimits.validate(fileURL: url, kind: kind)
        #expect(bytes == 500_000_000)
      } catch let error as AttachmentSizeLimitError {
        #expect(bytes == 500_000_001)
        #expect(error.localizedDescription.contains("500 MB"))
      }
    }
  }

  @Test("failed upload attempts retain a clear retry label while pending")
  func retryLabel() {
    #expect(UploadProgressSnapshot.failed(id: "document_1", error: nil).pendingRetryDescription == "Waiting to retry")
    #expect(UploadProgressSnapshot.processing(id: "document_1").pendingRetryDescription == nil)
  }

  @Test("resend keeps a failed document's local identity and iOS voice content")
  @MainActor
  func resendKeepsMedia() {
    var voice = Client_MessageVoiceContent()
    voice.voiceID = 99
    let message = Message(
      messageId: -1, fromId: 1, date: Date(), text: nil, peerUserId: 2,
      peerThreadId: nil, chatId: 1, out: true, status: .failed,
      contentPayload: Client_MessageContentPayload.with { $0.voice = voice }
    )
    let document = Document(
      id: 42, documentId: -42, date: Date(), fileName: "file.zip", mimeType: "application/zip",
      size: 500_000_000, localPath: "file.zip"
    )
    var full = FullMessage(senderInfo: nil, message: message, reactions: [], repliedToMessage: nil, attachments: [])
    full.documentInfo = DocumentInfo(document: document)
    let media = FailedMessageResender.mediaItems(for: full)
    #expect(media.count == 2)
    #expect(media.first?.asDocumentId() == -42)
    #expect(media.last?.asVoiceContent()?.voiceID == 99)
  }

  @Test("rejected resend admission or account change preserves the failed row", arguments: [false, true])
  @MainActor
  func failedResendPreservesOriginal(changeAccount: Bool) async throws {
    let auth = Auth.mocked(authenticated: true)
    let database = try AppDatabase(DatabaseQueue(configuration: AppDatabase.makeConfiguration(passphrase: "123")))
    let messageID: Int64 = changeAccount ? -11 : -10
    let message = Message(
      messageId: messageID, fromId: 1, date: Date(), text: "caption", peerUserId: nil,
      peerThreadId: 1, chatId: 1, out: true, status: .failed
    )
    try await database.dbWriter.write { db in
      try User(id: 1, email: nil, firstName: "Sender").insert(db)
      try Chat(id: 1, date: Date(), type: .thread, title: "Test", spaceId: nil).insert(db)
      try message.save(db)
    }
    let full = FullMessage(senderInfo: nil, message: message, reactions: [], repliedToMessage: nil, attachments: [])
    var admitted = false
    do {
      try await FailedMessageResender.resend(full, database: database, auth: auth.handle, beforeAdmission: {
        if changeAccount { try await auth.saveCredentials(token: "2:test-only", userId: 2) }
      }) { _ in admitted = true; return false }
    } catch {
      #expect(changeAccount)
    }
    #expect(admitted == !changeAccount)
    let stored = try await database.dbWriter.read { db in
      try Message.fetchOne(db, key: ["messageId": messageID, "chatId": 1])
    }
    #expect(stored?.status == .failed)
    #expect(stored?.text == "caption")
  }
}
