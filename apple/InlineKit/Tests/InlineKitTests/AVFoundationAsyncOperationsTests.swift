import AVFoundation
import Foundation
import Testing
@testable import InlineKit

@Suite("AVFoundation Async Operations")
struct AVFoundationAsyncOperationsTests {
  @Test("extracts a video frame through the native async image API")
  func extractsImage() async throws {
    let videoURL = try await makeTestVideoURL()
    defer { try? FileManager.default.removeItem(at: videoURL) }

    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: videoURL))
    generator.appliesPreferredTrackTransform = true
    let image = try await AVFoundationAsyncOperations.image(using: generator, at: .zero)

    #expect(image.width == 64)
    #expect(image.height == 64)
  }

  @Test("removes partial output when a file-producing operation is cancelled")
  func cancellationRemovesPartialOutput() async throws {
    let outputURL = temporaryURL(name: "cancelled")
    defer { try? FileManager.default.removeItem(at: outputURL) }

    let operation = Task {
      try await AVFoundationAsyncOperations.withCleanedDestination(at: outputURL) {
        try Data("partial".utf8).write(to: outputURL, options: .atomic)
        try await Task.sleep(for: .seconds(30))
      }
    }

    for _ in 0 ..< 100 where !FileManager.default.fileExists(atPath: outputURL.path) {
      try await Task.sleep(for: .milliseconds(1))
    }
    #expect(FileManager.default.fileExists(atPath: outputURL.path))

    operation.cancel()
    do {
      try await operation.value
      Issue.record("Expected cancellation")
    } catch is CancellationError {
      // Expected.
    }

    #expect(!FileManager.default.fileExists(atPath: outputURL.path))
  }

  @Test("an already-cancelled operation preserves an existing destination")
  func preCancelledOperationDoesNotMutateDestination() async throws {
    let outputURL = temporaryURL(name: "pre-cancelled")
    let original = Data("original".utf8)
    try original.write(to: outputURL, options: .atomic)
    defer { try? FileManager.default.removeItem(at: outputURL) }

    let wasCancelled = await Task {
      withUnsafeCurrentTask { task in
        task?.cancel()
      }

      do {
        try await AVFoundationAsyncOperations.withCleanedDestination(at: outputURL) {
          try Data("replacement".utf8).write(to: outputURL, options: .atomic)
        }
        return false
      } catch is CancellationError {
        return true
      } catch {
        return false
      }
    }.value

    #expect(wasCancelled)
    #expect(try Data(contentsOf: outputURL) == original)
  }

  @Test("keeps completed output")
  func successKeepsOutput() async throws {
    let outputURL = temporaryURL(name: "success")
    let expected = Data("complete".utf8)
    try Data("stale".utf8).write(to: outputURL, options: .atomic)
    defer { try? FileManager.default.removeItem(at: outputURL) }

    try await AVFoundationAsyncOperations.withCleanedDestination(at: outputURL) {
      try expected.write(to: outputURL, options: .atomic)
    }

    #expect(try Data(contentsOf: outputURL) == expected)
  }

  private func temporaryURL(name: String) -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("inlinekit_async_media_\(name)_\(UUID().uuidString).tmp")
  }
}
