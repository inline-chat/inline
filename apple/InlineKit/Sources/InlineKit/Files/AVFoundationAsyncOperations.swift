import AVFoundation
import Foundation

/// Narrow compatibility boundary for AVFoundation's structured-concurrency media APIs.
///
/// InlineKit's iOS 18/macOS 15 floor supports these APIs without availability gates.
/// Keeping file cleanup here prevents every export caller from having to correctly
/// reconcile cancellation with partially-written output files.
enum AVFoundationAsyncOperations {
  static func image(
    using generator: AVAssetImageGenerator,
    at time: CMTime,
    isolation: isolated (any Actor)? = #isolation
  ) async throws -> CGImage {
    let cancellation = ImageGenerationCancellation(generator)

    return try await withTaskCancellationHandler {
      try Task.checkCancellation()
      let result = try await cancellation.generator.image(at: time)
      try Task.checkCancellation()
      return result.image
    } onCancel: {
      cancellation.cancel()
    }
  }

  static func export(
    using session: AVAssetExportSession,
    to destinationURL: URL,
    as fileType: AVFileType,
    isolation: isolated (any Actor)? = #isolation
  ) async throws {
    try await withCleanedDestination(at: destinationURL) {
      // This native async API propagates cancellation from the initiating task.
      try await session.export(to: destinationURL, as: fileType)
    }
  }

  /// Runs one file-producing operation and removes an incomplete destination after
  /// failures or cancellation. An already-cancelled task leaves an existing file alone.
  static func withCleanedDestination<Result>(
    at destinationURL: URL,
    isolation: isolated (any Actor)? = #isolation,
    operation: () async throws -> Result
  ) async throws -> Result {
    try Task.checkCancellation()

    if FileManager.default.fileExists(atPath: destinationURL.path) {
      try FileManager.default.removeItem(at: destinationURL)
    }

    do {
      let result = try await operation()
      try Task.checkCancellation()
      return result
    } catch {
      if FileManager.default.fileExists(atPath: destinationURL.path) {
        try? FileManager.default.removeItem(at: destinationURL)
      }
      throw error
    }
  }
}

/// AVAssetImageGenerator documents `cancelAllCGImageGeneration()` as safe while an
/// asynchronous image request is outstanding. The unchecked boundary is private and
/// owns exactly that generator/request pair; no other mutable state crosses isolation.
private final class ImageGenerationCancellation: @unchecked Sendable {
  let generator: AVAssetImageGenerator

  init(_ generator: AVAssetImageGenerator) {
    self.generator = generator
  }

  func cancel() {
    generator.cancelAllCGImageGeneration()
  }
}
