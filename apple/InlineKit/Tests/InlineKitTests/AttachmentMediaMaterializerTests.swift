import Foundation
import Testing

@testable import InlineKit

@Suite("Attachment media materializer")
struct AttachmentMediaMaterializerTests {
  @Test("keeps preferred rich media when preparation succeeds")
  func keepsPreferredMedia() async throws {
    let probe = FallbackProbe()

    let value = try await AttachmentMediaMaterializer.withBareFileFallback {
      "media"
    } fallback: {
      await probe.recordFallback()
      return "file"
    }

    #expect(value == "media")
    #expect(await !probe.wasUsed)
  }

  @Test("uses a bare file when rich preparation fails")
  func fallsBackToBareFile() async throws {
    let value = try await AttachmentMediaMaterializer.withBareFileFallback {
      throw MaterializationStubError.preferred
    } fallback: {
      "file"
    }

    #expect(value == "file")
  }

  @Test("cancellation never creates a fallback attachment")
  func cancellationDoesNotFallback() async {
    let probe = FallbackProbe()

    do {
      let _: String = try await AttachmentMediaMaterializer.withBareFileFallback {
        throw CancellationError()
      } fallback: {
        await probe.recordFallback()
        return "file"
      }
      Issue.record("Expected cancellation")
    } catch is CancellationError {
      // Expected: cancellation must bypass fallback.
    } catch {
      Issue.record("Unexpected error: \(error)")
    }

    #expect(await !probe.wasUsed)
  }

  @Test("reports a terminal failure when media and file preparation both fail")
  func reportsTerminalFailure() async {
    do {
      _ = try await AttachmentMediaMaterializer.withBareFileFallback {
        throw MaterializationStubError.preferred
      } fallback: {
        throw MaterializationStubError.fallback
      }
      Issue.record("Expected the fallback failure")
    } catch let error as MaterializationStubError {
      #expect(error == .fallback)
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
  }
}

private enum MaterializationStubError: Error, Equatable {
  case preferred
  case fallback
}

private actor FallbackProbe {
  private(set) var wasUsed = false

  func recordFallback() {
    wasUsed = true
  }
}
