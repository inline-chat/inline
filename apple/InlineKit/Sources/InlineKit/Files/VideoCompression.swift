import AVFoundation
import AudioToolbox
import Foundation
import Logger

public enum VideoCompressionError: Error {
  case invalidAsset
  case exportFailed
  case unsupportedOutputType
}

/// What a video shows, which decides how it is encoded. Screen recordings carry code and UI text
/// and cost little at high resolution, because the encoder only spends bits where pixels change.
/// Camera footage changes everywhere, so resolution costs real bytes and send time.
public enum VideoContent: String, Sendable, Equatable {
  /// The file names the camera that recorded it.
  case camera
  /// Screen recordings, and anything else with no camera recorded in the file.
  case screenRecording
}

public struct VideoCompressionOptions: Sendable, Equatable {
  /// Longest edge of the output.
  public let maxDimension: Int
  /// Average video bitrate when re-encoding.
  public let videoBitrateKbps: Int
  public let audioBitrateKbps: Int
  /// Re-encode even a source within limits (one whose codec can't go in an MP4 as is).
  public let forceTranscode: Bool

  public init(maxDimension: Int, videoBitrateKbps: Int, audioBitrateKbps: Int = 128, forceTranscode: Bool = false) {
    self.maxDimension = maxDimension
    self.videoBitrateKbps = videoBitrateKbps
    self.audioBitrateKbps = audioBitrateKbps
    self.forceTranscode = forceTranscode
  }

  public static func upload(for content: VideoContent, forceTranscode: Bool = false) -> VideoCompressionOptions {
    switch content {
    case .camera:
      VideoCompressionOptions(maxDimension: 1_280, videoBitrateKbps: 3_000, forceTranscode: forceTranscode)
    case .screenRecording:
      VideoCompressionOptions(maxDimension: 1_920, videoBitrateKbps: 5_000, forceTranscode: forceTranscode)
    }
  }

  /// A source at or under this total bitrate is sent without re-encoding.
  var passthroughBitrateMbps: Double {
    Double(videoBitrateKbps + audioBitrateKbps) * 1.15 / 1_000
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

  /// Exports at once. An album starts every item's upload together; unbounded, ten exports
  /// competed for the encoder, each running into its 10-minute deadline (after which the
  /// original, possibly too large, file is sent). The deadline starts when an export does.
  static let maximumConcurrentExports = 2
  private var runningExports = 0
  private var exportWaiters: [(id: UUID, continuation: CheckedContinuation<Bool, Never>)] = []

  private init() {}

  private func acquireExportSlot() async throws {
    if runningExports < Self.maximumConcurrentExports, exportWaiters.isEmpty {
      runningExports += 1
      return
    }
    let id = UUID()
    let granted = await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        guard !Task.isCancelled else { return continuation.resume(returning: false) }
        exportWaiters.append((id, continuation))
      }
    } onCancel: {
      Task { await self.cancelExportWaiter(id) }
    }
    guard granted else { throw CancellationError() }
  }

  private func releaseExportSlot() {
    if exportWaiters.isEmpty {
      runningExports -= 1
    } else {
      exportWaiters.removeFirst().continuation.resume(returning: true)
    }
  }

  private func cancelExportWaiter(_ id: UUID) {
    guard let index = exportWaiters.firstIndex(where: { $0.id == id }) else { return }
    exportWaiters.remove(at: index).continuation.resume(returning: false)
  }

  func normalizeToMP4(at sourceURL: URL) async throws -> VideoCompressionResult {
    try await acquireExportSlot()
    defer { releaseExportSlot() }
    let box = PreparationAssetBox(AVURLAsset(url: sourceURL))
    return try await TransferPreparation.withDeadline(seconds: 600, cancel: { box.asset.cancelLoading() }) { [self] in
      try await normalizeToMP4Unbounded(at: sourceURL, asset: box.asset)
    }
  }

  private func normalizeToMP4Unbounded(at sourceURL: URL, asset: AVURLAsset) async throws -> VideoCompressionResult {
    let compatiblePresets = AVAssetExportSession.exportPresets(compatibleWith: asset)
    let tempURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("normalized_\(UUID().uuidString).mp4")

    if FileManager.default.fileExists(atPath: tempURL.path) {
      try FileManager.default.removeItem(at: tempURL)
    }

    var shouldCleanupTemp = true
    defer {
      if shouldCleanupTemp, FileManager.default.fileExists(atPath: tempURL.path) {
        try? FileManager.default.removeItem(at: tempURL)
      }
    }

    if compatiblePresets.contains(AVAssetExportPresetPassthrough) {
      do {
        try await export(asset: asset, presetName: AVAssetExportPresetPassthrough, destinationURL: tempURL)
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        log.debug("Passthrough MP4 normalization failed, falling back to highest-quality export")
      }
    }

    if !FileManager.default.fileExists(atPath: tempURL.path) {
      let fallbackPreset = [
        AVAssetExportPresetHighestQuality,
        AVAssetExportPresetMediumQuality,
        AVAssetExportPresetLowQuality,
      ].first(where: compatiblePresets.contains)

      guard let fallbackPreset else {
        throw VideoCompressionError.exportFailed
      }

      try await export(asset: asset, presetName: fallbackPreset, destinationURL: tempURL)
    }

    let outputMetadata = try await loadMetadata(for: AVURLAsset(url: tempURL))
    let outputSize = fileSize(for: tempURL)
    shouldCleanupTemp = false

    return VideoCompressionResult(
      url: tempURL,
      width: outputMetadata.width,
      height: outputMetadata.height,
      duration: outputMetadata.duration,
      fileSize: outputSize
    )
  }

  public func compressVideo(at sourceURL: URL, options: VideoCompressionOptions) async throws -> VideoCompressionResult {
    try await acquireExportSlot()
    defer { releaseExportSlot() }
    let box = PreparationAssetBox(AVURLAsset(url: sourceURL))
    return try await TransferPreparation.withDeadline(seconds: 600, cancel: { box.asset.cancelLoading() }) { [self] in
      try await compressVideoUnbounded(at: sourceURL, asset: box.asset, options: options)
    }
  }

  /// Always returns a new file with no location, device or date metadata: the source is either
  /// remuxed as is (already H.264 within size and bitrate, so nothing to wait for) or re-encoded.
  /// It never hands back the source itself.
  private func compressVideoUnbounded(at sourceURL: URL, asset: AVURLAsset, options: VideoCompressionOptions) async throws -> VideoCompressionResult {
    let metadata = try await loadMetadata(for: asset)
    let sourceFileSize = fileSize(for: sourceURL)
    let maxDimension = max(metadata.width, metadata.height)
    let bitrateMbps = estimatedBitrateMbps(fileSize: sourceFileSize, duration: metadata.duration)
    let isH264 = await Self.isH264(asset)
    let compatiblePresets = AVAssetExportSession.exportPresets(compatibleWith: asset)

    let canPassThrough = !options.forceTranscode
      && isH264
      && maxDimension <= options.maxDimension
      && bitrateMbps <= options.passthroughBitrateMbps
      && compatiblePresets.contains(AVAssetExportPresetPassthrough)

    log.debug(
      "Video check for \(sourceURL.lastPathComponent): size=\(sourceFileSize) bytes, max=\(maxDimension), bitrate=\(String(format: "%.2f", bitrateMbps)) Mbps, h264=\(isH264), passthrough=\(canPassThrough)"
    )

    let tempURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("compressed_\(UUID().uuidString).mp4")
    var shouldCleanupTemp = true
    defer {
      if shouldCleanupTemp, FileManager.default.fileExists(atPath: tempURL.path) {
        try? FileManager.default.removeItem(at: tempURL)
      }
    }

    var wrote = false
    if canPassThrough {
      do {
        try await export(asset: asset, presetName: AVAssetExportPresetPassthrough, destinationURL: tempURL)
        wrote = true
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        log.debug("Passthrough MP4 remux failed, re-encoding instead")
      }
    }

    if !wrote {
      do {
        try await transcodeTelegramStyle(asset: asset, options: options, destinationURL: tempURL)
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        log.warning("Video transcode failed, falling back to export preset: \(error.localizedDescription)")
        PerformanceTrace.healthEvent("app.fallback", data: ["fallback_kind": "video_transcode_export_preset"])
        guard let presetName = selectPreset(
          maxDimension: maxDimension,
          targetMaxDimension: options.maxDimension,
          compatiblePresets: compatiblePresets
        ) else {
          throw VideoCompressionError.exportFailed
        }
        try await export(asset: asset, presetName: presetName, destinationURL: tempURL)
      }
    }

    let outputSize = fileSize(for: tempURL)
    log.debug("Video prepared: original=\(sourceFileSize) bytes, sent=\(outputSize) bytes, remuxed=\(wrote)")

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

  /// Whether the file records the camera that made it, which marks camera footage.
  public static func content(of url: URL) async -> VideoContent {
    let asset = AVURLAsset(url: url)
    guard let items = try? await asset.load(.metadata) else { return .screenRecording }
    for item in items {
      let isCameraKey = item.identifier == .quickTimeMetadataMake
        || item.identifier == .quickTimeMetadataModel
        || item.identifier == .quickTimeUserDataMake
        || item.identifier == .quickTimeUserDataModel
        || item.commonKey == .commonKeyMake
        || item.commonKey == .commonKeyModel
      guard isCameraKey else { continue }
      if let value = try? await item.load(.stringValue),
         !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      {
        return .camera
      }
    }
    return .screenRecording
  }

  static func isH264(_ asset: AVAsset) async -> Bool {
    guard let track = try? await asset.loadTracks(withMediaType: .video).first,
          let format = try? await track.load(.formatDescriptions).first
    else {
      return false
    }
    return CMFormatDescriptionGetMediaSubType(format) == kCMVideoCodecType_H264
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
    // Drops where and on what device it was recorded, and other personal details.
    exportSession.metadataItemFilter = AVMetadataItemFilter.forSharing()

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

    let outputSize = targetRenderSize(for: sourceDisplaySize, maxDimension: options.maxDimension)
    let frameRate = targetFrameRate(for: sourceVideoTrack, capTo30FPS: true)
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
        targetVideoBitrate: options.videoBitrateKbps * 1_000
      )
    )
    videoInput.expectsMediaDataInRealTime = false
    guard writer.canAdd(videoInput) else {
      throw VideoCompressionError.exportFailed
    }
    writer.add(videoInput)

    var audioOutput: AVAssetReaderTrackOutput?
    var audioInput: AVAssetWriterInput?
    if let compositionAudioTrack, let telegramAudioSettings = makeAudioSettings(bitrateKbps: options.audioBitrateKbps) {
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
        cancellation: cancellationBox,
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
          cancellation: cancellationBox,
          group: group
        )
      }

      await withTaskCancellationHandler {
        await waitForGroup(group)
      } onCancel: {
        cancellationBox.cancel()
      }
      try Task.checkCancellation()

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
    cancellation: TranscodeCancellationBox,
    group: DispatchGroup
  ) {
    group.enter()
    let completionState = StreamCompletionState()

    let complete: @Sendable () -> Void = {
      completionState.completeOnce {
        input.input.markAsFinished()
        group.leave()
      }
    }

    // A writer that never asks for another sample must still release its group
    // on cancellation. Complete on the same queue as sample processing.
    cancellation.registerCompletion { queue.async(execute: complete) }

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

  private func makeAudioSettings(bitrateKbps: Int) -> [String: Any]? {
    guard bitrateKbps > 0 else { return nil }
    var layout = AudioChannelLayout()
    layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
    return [
      AVFormatIDKey: kAudioFormatMPEG4AAC,
      AVSampleRateKey: 44_100,
      AVEncoderBitRateKey: bitrateKbps * 1_000,
      AVNumberOfChannelsKey: 2,
      AVChannelLayoutKey: Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size),
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
    let box = PreparationAssetBox(asset)
    return try await TransferPreparation.withDeadline(seconds: 30, cancel: { box.asset.cancelLoading() }) { [self] in
      try await loadMetadataUnbounded(for: box.asset)
    }
  }

  private func loadMetadataUnbounded(for asset: AVURLAsset) async throws -> (width: Int, height: Int, duration: Int) {
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

final class PreparationAssetBox: @unchecked Sendable {
  let asset: AVURLAsset
  init(_ asset: AVURLAsset) { self.asset = asset }
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
  private var cancelled = false
  private var completions: [@Sendable () -> Void] = []

  init(reader: AssetReaderBox, writer: AssetWriterBox) {
    self.reader = reader
    self.writer = writer
  }

  func cancel() {
    lock.lock()
    guard !cancelled else { lock.unlock(); return }
    cancelled = true
    let callbacks = completions
    completions.removeAll()
    lock.unlock()
    reader.reader.cancelReading()
    writer.writer.cancelWriting()
    for callback in callbacks { callback() }
  }

  func registerCompletion(_ callback: @escaping @Sendable () -> Void) {
    lock.lock()
    if cancelled {
      lock.unlock()
      callback()
    } else {
      completions.append(callback)
      lock.unlock()
    }
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
