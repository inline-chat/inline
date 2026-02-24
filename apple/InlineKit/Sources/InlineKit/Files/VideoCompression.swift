import AVFoundation
import AudioToolbox
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
      maxDimension: 1_280,
      minFileSizeBytes: 8_000_000,
      maxBitrateMbps: 3.0,
      minimumCompressionRatio: 0.94,
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

    do {
      try await transcodeTelegramStyle(asset: asset, options: options, destinationURL: tempURL)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      log.warning("Telegram-style transcode failed, falling back to export preset: \(error.localizedDescription)")
      guard let presetName = selectPreset(
        maxDimension: maxDimension,
        targetMaxDimension: options.maxDimension,
        compatiblePresets: compatiblePresets
      ) else {
        throw VideoCompressionError.exportFailed
      }
      try await export(asset: asset, presetName: presetName, destinationURL: tempURL)
    }

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
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        sessionBox.session.exportAsynchronously {
          switch sessionBox.session.status {
          case .completed:
            continuation.resume()
          case .cancelled:
            continuation.resume(throwing: CancellationError())
          case .failed:
            continuation.resume(throwing: sessionBox.session.error ?? VideoCompressionError.exportFailed)
          default:
            continuation.resume(throwing: VideoCompressionError.exportFailed)
          }
        }
      }
    } onCancel: {
      sessionBox.session.cancelExport()
    }
  }

  private func transcodeTelegramStyle(
    asset: AVURLAsset,
    options: VideoCompressionOptions,
    destinationURL: URL
  ) async throws {
    if FileManager.default.fileExists(atPath: destinationURL.path) {
      try FileManager.default.removeItem(at: destinationURL)
    }

    let tracks = try await asset.loadTracks(withMediaType: .video)
    guard let sourceVideoTrack = tracks.first else {
      throw VideoCompressionError.invalidAsset
    }

    let naturalSize = try await sourceVideoTrack.load(.naturalSize)
    let preferredTransform = try await sourceVideoTrack.load(.preferredTransform)
    let transformedRect = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
    let sourceDisplaySize = CGSize(width: abs(transformedRect.width), height: abs(transformedRect.height))
    guard sourceDisplaySize.width > 0, sourceDisplaySize.height > 0 else {
      throw VideoCompressionError.invalidAsset
    }

    let telegramPreset = telegramPreset(for: options)
    let outputSize = targetRenderSize(for: sourceDisplaySize, maxDimension: telegramPreset.maxDimension)
    let frameRate = targetFrameRate(for: sourceVideoTrack, capTo30FPS: telegramPreset.capsFrameRateTo30FPS)
    let duration = try await asset.load(.duration)
    guard duration.isValid, duration.seconds > 0 else {
      throw VideoCompressionError.invalidAsset
    }

    let composition = AVMutableComposition()
    guard let compositionVideoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
    else {
      throw VideoCompressionError.exportFailed
    }
    try compositionVideoTrack.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: sourceVideoTrack, at: .zero)

    let sourceAudioTracks = try await asset.loadTracks(withMediaType: .audio)
    var compositionAudioTrack: AVMutableCompositionTrack?
    if let sourceAudioTrack = sourceAudioTracks.first,
       let addedAudioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
    {
      do {
        try addedAudioTrack.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: sourceAudioTrack, at: .zero)
        compositionAudioTrack = addedAudioTrack
      } catch {
        log.warning("Failed to include source audio during video transcode: \(error.localizedDescription)")
      }
    }

    let videoComposition = AVMutableVideoComposition()
    videoComposition.renderSize = outputSize
    videoComposition.frameDuration = CMTime(value: 1, timescale: frameRate)

    let instruction = AVMutableVideoCompositionInstruction()
    instruction.timeRange = CMTimeRange(start: .zero, duration: duration)

    let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: compositionVideoTrack)
    let scale = min(
      outputSize.width / max(sourceDisplaySize.width, 1),
      outputSize.height / max(sourceDisplaySize.height, 1)
    )

    var transform = preferredTransform.concatenating(CGAffineTransform(scaleX: scale, y: scale))
    let scaledRect = CGRect(origin: .zero, size: naturalSize).applying(transform)
    let xOffset = (outputSize.width - abs(scaledRect.width)) / 2.0 - scaledRect.minX
    let yOffset = (outputSize.height - abs(scaledRect.height)) / 2.0 - scaledRect.minY
    transform = transform.concatenating(CGAffineTransform(translationX: xOffset, y: yOffset))
    layerInstruction.setTransform(transform, at: .zero)

    instruction.layerInstructions = [layerInstruction]
    videoComposition.instructions = [instruction]

    let reader = try AVAssetReader(asset: composition)
    let writer = try AVAssetWriter(outputURL: destinationURL, fileType: .mp4)
    writer.shouldOptimizeForNetworkUse = true

    let videoOutput = AVAssetReaderVideoCompositionOutput(
      videoTracks: [compositionVideoTrack],
      videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
    )
    videoOutput.videoComposition = videoComposition
    videoOutput.alwaysCopiesSampleData = false
    guard reader.canAdd(videoOutput) else {
      throw VideoCompressionError.exportFailed
    }
    reader.add(videoOutput)

    let videoInput = AVAssetWriterInput(
      mediaType: .video,
      outputSettings: makeTelegramVideoSettings(
        dimensions: outputSize,
        frameRate: frameRate,
        targetVideoBitrate: telegramPreset.videoBitrateKbps * 1_000
      )
    )
    videoInput.expectsMediaDataInRealTime = false
    guard writer.canAdd(videoInput) else {
      throw VideoCompressionError.exportFailed
    }
    writer.add(videoInput)

    var audioOutput: AVAssetReaderTrackOutput?
    var audioInput: AVAssetWriterInput?
    if let compositionAudioTrack, let telegramAudioSettings = makeTelegramAudioSettings(preset: telegramPreset) {
      let output = AVAssetReaderTrackOutput(
        track: compositionAudioTrack,
        outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM]
      )
      output.alwaysCopiesSampleData = false
      let input = AVAssetWriterInput(mediaType: .audio, outputSettings: telegramAudioSettings)
      input.expectsMediaDataInRealTime = false
      if reader.canAdd(output), writer.canAdd(input) {
        reader.add(output)
        writer.add(input)
        audioOutput = output
        audioInput = input
      }
    }

    let readerBox = AssetReaderBox(reader)
    let writerBox = AssetWriterBox(writer)
    let videoOutputBox = AssetReaderOutputBox(videoOutput)
    let videoInputBox = AssetWriterInputBox(videoInput)
    let audioOutputBox = audioOutput.map(AssetReaderOutputBox.init)
    let audioInputBox = audioInput.map(AssetWriterInputBox.init)

    let cancellationBox = TranscodeCancellationBox(reader: readerBox, writer: writerBox)
    try await withTaskCancellationHandler {
      guard readerBox.reader.startReading() else {
        throw readerBox.reader.error ?? VideoCompressionError.exportFailed
      }
      guard writerBox.writer.startWriting() else {
        throw writerBox.writer.error ?? VideoCompressionError.exportFailed
      }
      writerBox.writer.startSession(atSourceTime: .zero)

      let failureState = TranscodeFailureState()
      let group = DispatchGroup()

      processSamples(
        output: videoOutputBox,
        input: videoInputBox,
        reader: readerBox,
        writer: writerBox,
        queue: DispatchQueue(label: "inline.video.compress.video"),
        failureState: failureState,
        group: group
      )

      if let audioOutputBox, let audioInputBox {
        processSamples(
          output: audioOutputBox,
          input: audioInputBox,
          reader: readerBox,
          writer: writerBox,
          queue: DispatchQueue(label: "inline.video.compress.audio"),
          failureState: failureState,
          group: group
        )
      }

      await waitForGroup(group)

      if let error = failureState.error {
        writerBox.writer.cancelWriting()
        throw error
      }

      if readerBox.reader.status == .failed {
        writerBox.writer.cancelWriting()
        throw readerBox.reader.error ?? VideoCompressionError.exportFailed
      }
      if readerBox.reader.status == .cancelled {
        writerBox.writer.cancelWriting()
        throw CancellationError()
      }

      try await finishWriting(writerBox)
      guard writerBox.writer.status == .completed else {
        throw writerBox.writer.error ?? VideoCompressionError.exportFailed
      }
    } onCancel: {
      cancellationBox.cancel()
    }
  }

  private func processSamples(
    output: AssetReaderOutputBox,
    input: AssetWriterInputBox,
    reader: AssetReaderBox,
    writer: AssetWriterBox,
    queue: DispatchQueue,
    failureState: TranscodeFailureState,
    group: DispatchGroup
  ) {
    group.enter()
    let completionState = StreamCompletionState()

    let complete: () -> Void = {
      completionState.completeOnce {
        input.input.markAsFinished()
        group.leave()
      }
    }

    input.input.requestMediaDataWhenReady(on: queue) {
      while input.input.isReadyForMoreMediaData {
        if completionState.isCompleted { return }
        if let _ = failureState.error {
          complete()
          return
        }
        if Task.isCancelled {
          failureState.setError(CancellationError())
          reader.reader.cancelReading()
          complete()
          return
        }

        guard reader.reader.status == .reading else {
          complete()
          return
        }

        guard let sampleBuffer = output.output.copyNextSampleBuffer() else {
          complete()
          return
        }

        if !input.input.append(sampleBuffer) {
          failureState.setError(writer.writer.error ?? reader.reader.error ?? VideoCompressionError.exportFailed)
          reader.reader.cancelReading()
          complete()
          return
        }
      }
    }
  }

  private func makeTelegramVideoSettings(
    dimensions: CGSize,
    frameRate: Int32,
    targetVideoBitrate: Int
  ) -> [String: Any] {
    let cleanAperture: [String: Any] = [
      AVVideoCleanApertureWidthKey: Int(dimensions.width),
      AVVideoCleanApertureHeightKey: Int(dimensions.height),
      AVVideoCleanApertureHorizontalOffsetKey: 10,
      AVVideoCleanApertureVerticalOffsetKey: 10
    ]
    let pixelAspectRatio: [String: Any] = [
      AVVideoPixelAspectRatioHorizontalSpacingKey: 3,
      AVVideoPixelAspectRatioVerticalSpacingKey: 3
    ]

    let compressionProperties: [String: Any] = [
      AVVideoAverageBitRateKey: targetVideoBitrate,
      AVVideoCleanApertureKey: cleanAperture,
      AVVideoPixelAspectRatioKey: pixelAspectRatio,
      AVVideoExpectedSourceFrameRateKey: Int(frameRate),
      AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
      AVVideoH264EntropyModeKey: AVVideoH264EntropyModeCABAC
    ]

    return [
      AVVideoCodecKey: AVVideoCodecType.h264,
      AVVideoCompressionPropertiesKey: compressionProperties,
      AVVideoWidthKey: Int(dimensions.width),
      AVVideoHeightKey: Int(dimensions.height),
      AVVideoColorPropertiesKey: [
        AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
        AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
      ]
    ]
  }

  private func makeTelegramAudioSettings(preset: TelegramVideoCompressionPreset) -> [String: Any]? {
    guard preset.audioBitrateKbps > 0, preset.audioChannels > 0 else {
      return nil
    }

    var layout = AudioChannelLayout()
    layout.mChannelLayoutTag = preset.audioChannels > 1 ? kAudioChannelLayoutTag_Stereo : kAudioChannelLayoutTag_Mono

    return [
      AVFormatIDKey: kAudioFormatMPEG4AAC,
      AVSampleRateKey: 44_100,
      AVEncoderBitRateKey: preset.audioBitrateKbps * 1_000,
      AVNumberOfChannelsKey: preset.audioChannels,
      AVChannelLayoutKey: Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size)
    ]
  }

  private func targetRenderSize(for sourceDisplaySize: CGSize, maxDimension: Int) -> CGSize {
    let safeMaxDimension = max(maxDimension, 16)
    let maxSide = max(sourceDisplaySize.width, sourceDisplaySize.height)
    let scale = maxSide > CGFloat(safeMaxDimension) ? CGFloat(safeMaxDimension) / maxSide : 1.0
    let scaled = CGSize(width: sourceDisplaySize.width * scale, height: sourceDisplaySize.height * scale)

    var width = floor(scaled.width / 16.0) * 16.0
    if width < 16 { width = 16 }

    var height = floor((scaled.height * width) / max(scaled.width, 1))
    if height.truncatingRemainder(dividingBy: 16.0) != 0 {
      height = floor(scaled.height / 16.0) * 16.0
    }
    if height < 16 { height = 16 }

    return CGSize(width: width, height: height)
  }

  private func targetFrameRate(for track: AVAssetTrack, capTo30FPS: Bool) -> Int32 {
    var frameRate = Int32(30)
    if track.nominalFrameRate > 0 {
      frameRate = Int32(ceil(track.nominalFrameRate))
    } else {
      let minFrameDuration = track.minFrameDuration
      let seconds = CMTimeGetSeconds(minFrameDuration)
      if seconds.isFinite, seconds > 0 {
        frameRate = Int32(ceil(1.0 / seconds))
      }
    }

    return capTo30FPS ? max(1, min(frameRate, 30)) : max(1, frameRate)
  }

  private func telegramPreset(for options: VideoCompressionOptions) -> TelegramVideoCompressionPreset {
    TelegramVideoCompressionPreset.from(maxDimension: options.maxDimension, maxBitrateMbps: options.maxBitrateMbps)
  }

  private func waitForGroup(_ group: DispatchGroup) async {
    await withCheckedContinuation { continuation in
      group.notify(queue: DispatchQueue.global(qos: .userInitiated)) {
        continuation.resume()
      }
    }
  }

  private func finishWriting(_ writerBox: AssetWriterBox) async throws {
    try await withCheckedThrowingContinuation { continuation in
      writerBox.writer.finishWriting {
        switch writerBox.writer.status {
        case .completed:
          continuation.resume()
        case .cancelled:
          continuation.resume(throwing: CancellationError())
        case .failed:
          continuation.resume(throwing: writerBox.writer.error ?? VideoCompressionError.exportFailed)
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
        AVAssetExportPresetHighestQuality,
        AVAssetExportPresetMediumQuality,
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

private final class AssetWriterBox: @unchecked Sendable {
  let writer: AVAssetWriter

  init(_ writer: AVAssetWriter) {
    self.writer = writer
  }
}

private final class AssetReaderBox: @unchecked Sendable {
  let reader: AVAssetReader

  init(_ reader: AVAssetReader) {
    self.reader = reader
  }
}

private final class AssetReaderOutputBox: @unchecked Sendable {
  let output: AVAssetReaderOutput

  init(_ output: AVAssetReaderOutput) {
    self.output = output
  }
}

private final class AssetWriterInputBox: @unchecked Sendable {
  let input: AVAssetWriterInput

  init(_ input: AVAssetWriterInput) {
    self.input = input
  }
}

private final class TranscodeCancellationBox: @unchecked Sendable {
  private let lock = NSLock()
  private let reader: AssetReaderBox
  private let writer: AssetWriterBox

  init(reader: AssetReaderBox, writer: AssetWriterBox) {
    self.reader = reader
    self.writer = writer
  }

  func cancel() {
    lock.lock()
    defer { lock.unlock() }
    reader.reader.cancelReading()
    writer.writer.cancelWriting()
  }
}

private final class TranscodeFailureState: @unchecked Sendable {
  private let lock = NSLock()
  private var storedError: Error?

  var error: Error? {
    lock.lock()
    defer { lock.unlock() }
    return storedError
  }

  func setError(_ error: Error) {
    lock.lock()
    defer { lock.unlock() }
    if storedError == nil {
      storedError = error
    }
  }
}

private final class StreamCompletionState: @unchecked Sendable {
  private let lock = NSLock()
  private var completed = false

  var isCompleted: Bool {
    lock.lock()
    defer { lock.unlock() }
    return completed
  }

  func completeOnce(_ block: () -> Void) {
    let shouldRun: Bool
    lock.lock()
    if completed {
      shouldRun = false
    } else {
      completed = true
      shouldRun = true
    }
    lock.unlock()
    if shouldRun {
      block()
    }
  }
}

private enum TelegramVideoCompressionPreset: Sendable {
  case compressedVeryLow
  case compressedLow
  case compressedMedium
  case compressedHigh
  case compressedVeryHigh

  var maxDimension: Int {
    switch self {
    case .compressedVeryLow:
      return 480
    case .compressedLow:
      return 640
    case .compressedMedium:
      return 848
    case .compressedHigh:
      return 1_280
    case .compressedVeryHigh:
      return 1_920
    }
  }

  var videoBitrateKbps: Int {
    switch self {
    case .compressedVeryLow:
      return 400
    case .compressedLow:
      return 700
    case .compressedMedium:
      return 1_600
    case .compressedHigh:
      return 2_800
    case .compressedVeryHigh:
      return 6_600
    }
  }

  var audioBitrateKbps: Int {
    switch self {
    case .compressedVeryLow, .compressedLow:
      return 32
    case .compressedMedium, .compressedHigh, .compressedVeryHigh:
      return 64
    }
  }

  var audioChannels: Int {
    switch self {
    case .compressedVeryLow, .compressedLow:
      return 1
    case .compressedMedium, .compressedHigh, .compressedVeryHigh:
      return 2
    }
  }

  var capsFrameRateTo30FPS: Bool {
    self != .compressedVeryHigh
  }

  static func from(maxDimension: Int, maxBitrateMbps: Double) -> TelegramVideoCompressionPreset {
    if maxDimension >= 1_920 || maxBitrateMbps >= 6.6 {
      return .compressedVeryHigh
    } else if maxDimension >= 1_280 || maxBitrateMbps >= 3.0 {
      return .compressedHigh
    } else if maxDimension >= 848 || maxBitrateMbps >= 1.6 {
      return .compressedMedium
    } else if maxDimension >= 640 || maxBitrateMbps >= 0.7 {
      return .compressedLow
    } else {
      return .compressedVeryLow
    }
  }
}
