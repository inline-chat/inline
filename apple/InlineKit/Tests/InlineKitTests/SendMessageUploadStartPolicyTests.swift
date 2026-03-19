import Testing
@testable import InlineKit

@Suite("Send Message Upload Start Policy")
struct SendMessageUploadStartPolicyTests {
  @Test("swallows upload already in progress errors so send can join the existing upload")
  func swallowsUploadAlreadyInProgressError() async throws {
    await #expect(throws: Never.self) {
      try await SendMessageUploadCoordinator.beginOrJoinUpload {
        throw FileUploadError.uploadAlreadyInProgress
      }
    }
  }

  @Test("rethrows unrelated upload start errors")
  func rethrowsUnrelatedUploadStartErrors() async throws {
    await #expect(throws: FileUploadError.invalidDocument) {
      try await SendMessageUploadCoordinator.beginOrJoinUpload {
        throw FileUploadError.invalidDocument
      }
    }
  }
}
