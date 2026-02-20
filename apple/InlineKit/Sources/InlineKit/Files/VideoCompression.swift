import AVFoundation
import Foundation
import Logger

public enum VideoCompressionError: Error {
  case invalidAsset
  case compressionNotNeeded
  case compressionNotEffective
  case exportFailed
  case unsupportedOutputType
}

public struct VideoCompressionOptions: Sendable {
  public let maxDimension: Int
  public let minFileSizeBytes: Int64
  public let maxBitrateMbps: Double
  public let minimumCompressionRatio: Double
  public let forceTranscode: Bool

  public static func uploadDefault(forceTranscode: Bool = false) -> VideoCompressionOptions {
    VideoCompressionOptions(
      maxDimension: 960,
      minFileSizeBytes: 4_000_000,
      maxBitrateMbps: 4.5,
      minimumCompressionRatio: 0.9,
      forceTranscode: forceTranscode
    )
  }
}

public struct VideoCompressionResult: Sendable {
  public let url: URL
  public let width: Int
  public let height: Int
  public let duration: Int
  public let fileSize: Int64
}

public actor VideoCompressor {
  public static let shared = VideoCompressor()
  private let log = Log.scoped("VideoCompressor")

  private init() {}

  public func compressVideo(at sourceURL: URL, options: VideoCompressionOptions) async throws -> VideoCompressionResult {
    let asset = AVURLAsset(url: sourceURL)
    let metadata = try await loadMetadata(for: asset)
    let sourceFileSize = fileSize(for: sourceURL)
    let maxDimension = max(metadata.width, metadata.height)
    let bitrateMbps = estimatedBitrateMbps(fileSize: sourceFileSize, duration: metadata.duration)

    let shouldCompress = options.forceTranscode
      || maxDimension > options.maxDimension
      || sourceFileSize >= options.minFileSizeBytes
      || bitrateMbps > options.maxBitrateMbps

    log.debug(
      "Video compression check for \(sourceURL.lastPathComponent): size=\(sourceFileSize) bytes, max=\(maxDimension), bitrate=\(String(format: "%.2f", bitrateMbps)) Mbps, shouldCompress=\(shouldCompress)"
    )

    guard shouldCompress else {
      throw VideoCompressionError.compressionNotNeeded
    }

    let compatiblePresets = AVAssetExportSession.exportPresets(compatibleWith: asset)

    let tempURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("compressed_\(UUID().uuidString).mp4")
    if FileManager.default.fileExists(atPath: tempURL.path) {
      try FileManager.default.removeItem(at: tempURL)
    }
    var shouldCleanupTemp = true
    defer {
      if shouldCleanupTemp, FileManager.default.fileExists(atPath: tempURL.path) {
        try? FileManager.default.removeItem(at: tempURL)
      }
    }

    if shouldAttemptPassthroughTranscode(
      options: options,
      maxDimension: maxDimension,
      sourceFileSize: sourceFileSize,
      bitrateMbps: bitrateMbps,
      compatiblePresets: compatiblePresets
    ) {
      do {
        try await export(asset: asset, presetName: AVAssetExportPresetPassthrough, destinationURL: tempURL)
        let outputSize = fileSize(for: tempURL)
        let outputMetadata = try await loadMetadata(for: AVURLAsset(url: tempURL))
        shouldCleanupTemp = false

        log.debug(
          "Video fast MP4 conversion result: original=\(sourceFileSize) bytes, converted=\(outputSize) bytes"
        )

        return VideoCompressionResult(
          url: tempURL,
          width: outputMetadata.width,
          height: outputMetadata.height,
          duration: outputMetadata.duration,
          fileSize: outputSize
        )
      } catch {
        log.debug("Passthrough MP4 conversion failed, falling back to encoded export")
      }
    }

    guard let presetName = selectPreset(
      maxDimension: maxDimension,
      targetMaxDimension: options.maxDimension,
      compatiblePresets: compatiblePresets
    ) else {
      throw VideoCompressionError.exportFailed
    }

    try await export(asset: asset, presetName: presetName, destinationURL: tempURL)

    let outputSize = fileSize(for: tempURL)
    let compressionRatio = Double(outputSize) / Double(max(sourceFileSize, 1))

    log.debug(
      "Video compression result: original=\(sourceFileSize) bytes, compressed=\(outputSize) bytes, ratio=\(String(format: "%.2f", compressionRatio))"
    )

    if !options.forceTranscode && compressionRatio > options.minimumCompressionRatio {
      throw VideoCompressionError.compressionNotEffective
    }

    let outputMetadata = try await loadMetadata(for: AVURLAsset(url: tempURL))
    shouldCleanupTemp = false

    return VideoCompressionResult(
      url: tempURL,
      width: outputMetadata.width,
      height: outputMetadata.height,
      duration: outputMetadata.duration,
      fileSize: outputSize
    )
  }

  private func shouldAttemptPassthroughTranscode(
    options: VideoCompressionOptions,
    maxDimension: Int,
    sourceFileSize: Int64,
    bitrateMbps: Double,
    compatiblePresets: [String]
  ) -> Bool {
    guard options.forceTranscode else { return false }
    guard compatiblePresets.contains(AVAssetExportPresetPassthrough) else { return false }
    return maxDimension <= options.maxDimension
      && sourceFileSize < options.minFileSizeBytes
      && bitrateMbps <= options.maxBitrateMbps
  }

  private func export(asset: AVAsset, presetName: String, destinationURL: URL) async throws {
    if FileManager.default.fileExists(atPath: destinationURL.path) {
      try FileManager.default.removeItem(at: destinationURL)
    }

    guard let exportSession = AVAssetExportSession(asset: asset, presetName: presetName) else {
      throw VideoCompressionError.exportFailed
    }

    guard exportSession.supportedFileTypes.contains(.mp4) else {
      throw VideoCompressionError.unsupportedOutputType
    }

    exportSession.outputURL = destinationURL
    exportSession.outputFileType = .mp4
    exportSession.shouldOptimizeForNetworkUse = true

    let sessionBox = ExportSessionBox(exportSession)
    try await withCheckedThrowingContinuation { continuation in
      sessionBox.session.exportAsynchronously {
        switch sessionBox.session.status {
        case .completed:
          continuation.resume()
        case .failed, .cancelled:
          continuation.resume(throwing: sessionBox.session.error ?? VideoCompressionError.exportFailed)
        default:
          continuation.resume(throwing: VideoCompressionError.exportFailed)
        }
      }
    }
  }

  private func fileSize(for url: URL) -> Int64 {
    (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
  }

  private func estimatedBitrateMbps(fileSize: Int64, duration: Int) -> Double {
    guard duration > 0 else { return 0 }
    return (Double(fileSize) * 8.0) / Double(duration) / 1_000_000.0
  }

  private func loadMetadata(for asset: AVURLAsset) async throws -> (width: Int, height: Int, duration: Int) {
    let tracks = try await asset.loadTracks(withMediaType: .video)
    guard let track = tracks.first else { throw VideoCompressionError.invalidAsset }

    let naturalSize = try await track.load(.naturalSize)
    let preferredTransform = try await track.load(.preferredTransform)
    let transformedSize = naturalSize.applying(preferredTransform)

    let width = Int(abs(transformedSize.width.rounded()))
    let height = Int(abs(transformedSize.height.rounded()))
    guard width > 0, height > 0 else { throw VideoCompressionError.invalidAsset }

    let durationTime = try await asset.load(.duration)
    let seconds = CMTimeGetSeconds(durationTime)
    guard seconds.isFinite, seconds > 0 else { throw VideoCompressionError.invalidAsset }

    return (width: width, height: height, duration: Int(seconds.rounded()))
  }

  private func selectPreset(
    maxDimension: Int,
    targetMaxDimension: Int,
    compatiblePresets: [String]
  ) -> String? {
    if maxDimension <= targetMaxDimension {
      let preferredPresets = [
        AVAssetExportPresetMediumQuality,
        AVAssetExportPresetHighestQuality,
        AVAssetExportPresetLowQuality
      ]
      return preferredPresets.first { compatiblePresets.contains($0) }
    }

    let effectiveMaxDimension = min(maxDimension, targetMaxDimension)
    let preferredPresets: [String]
    if effectiveMaxDimension >= 1_280 {
      preferredPresets = [
        AVAssetExportPreset1280x720,
        AVAssetExportPreset960x540,
        AVAssetExportPresetMediumQuality,
        AVAssetExportPresetHighestQuality
      ]
    } else if effectiveMaxDimension >= 960 {
      preferredPresets = [
        AVAssetExportPreset960x540,
        AVAssetExportPreset640x480,
        AVAssetExportPresetMediumQuality,
        AVAssetExportPresetHighestQuality
      ]
    } else if effectiveMaxDimension >= 640 {
      preferredPresets = [
        AVAssetExportPreset640x480,
        AVAssetExportPresetMediumQuality,
        AVAssetExportPresetHighestQuality
      ]
    } else {
      preferredPresets = [
        AVAssetExportPresetMediumQuality,
        AVAssetExportPresetLowQuality,
        AVAssetExportPresetHighestQuality
      ]
    }

    return preferredPresets.first { compatiblePresets.contains($0) }
  }
}

private final class ExportSessionBox: @unchecked Sendable {
  let session: AVAssetExportSession

  init(_ session: AVAssetExportSession) {
    self.session = session
  }
}
