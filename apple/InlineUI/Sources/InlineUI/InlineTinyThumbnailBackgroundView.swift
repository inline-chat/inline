import CoreImage
import Foundation
import ImageIO
import InlineKit
import os.signpost

#if os(iOS)
import UIKit
#else
import AppKit
#endif

public enum InlineTinyThumbnailDecoder {
  private static let headerPattern = Data(base64Encoded:
    "/9j/2wBDACgcHiMeGSgjISMtKygwPGRBPDc3PHtYXUlkkYCZlo+AjIqgtObDoKrarYqMyP/L2u71////m8H////6/+b9//j/2wBDASstLTw1PHZBQXb4pYyl+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj/wAARCAAAAAADASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9o="
  )
  private static let footerPattern = Data(base64Encoded: "/9k=")
  private static let heightByteIndex = 145
  private static let widthByteIndex = 147

  public static func strippedBytes(from photoInfo: PhotoInfo?) -> Data? {
    photoInfo?.sizes.first { $0.type == "s" && $0.bytes?.isEmpty == false }?.bytes
      ?? photoInfo?.sizes.first { $0.bytes?.isEmpty == false }?.bytes
  }

  public static func decodeJPEGData(from strippedBytes: Data) -> Data? {
    guard strippedBytes.count >= 3,
          strippedBytes[0] == 1,
          let headerPattern,
          let footerPattern
    else {
      return nil
    }

    let height = UInt16(strippedBytes[1])
    let width = UInt16(strippedBytes[2])

    var result = Data()
    result.append(headerPattern)
    result.append(contentsOf: strippedBytes.dropFirst(3))
    result.append(footerPattern)

    guard result.count > (widthByteIndex + 1) else { return nil }

    result.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) in
      guard let bytes = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
      bytes[heightByteIndex] = UInt8((height >> 8) & 0xFF)
      bytes[heightByteIndex + 1] = UInt8(height & 0xFF)
      bytes[widthByteIndex] = UInt8((width >> 8) & 0xFF)
      bytes[widthByteIndex + 1] = UInt8(width & 0xFF)
    }

    return result
  }
}

public enum InlineTinyThumbnailWarmupPriority: Sendable {
  case speculative
  case nearby
  case visible

  fileprivate var renderPriority: TinyThumbnailRenderPriority {
    switch self {
      case .speculative: .speculative
      case .nearby: .nearby
      case .visible: .visible
    }
  }
}

public enum InlineTinyThumbnailWarmupPolicy {
  public static let firstPresentationMessageLimit = 12
  public static let firstPresentationTimeout: Duration = .milliseconds(8)
  public static let maximumLookaheadRows = 16

  public static func adaptiveLookaheadRows() -> Int {
    let thermalLimit: Int
    switch ProcessInfo.processInfo.thermalState {
      case .nominal: thermalLimit = maximumLookaheadRows
      case .fair: thermalLimit = 10
      case .serious: thermalLimit = 4
      case .critical: thermalLimit = 0
      @unknown default: thermalLimit = 4
    }

    if ProcessInfo.processInfo.isLowPowerModeEnabled {
      return min(thermalLimit, 8)
    }
    return thermalLimit
  }
}

public struct InlineTinyThumbnailWarmup: Sendable, Hashable {
  fileprivate let ownerID: UUID
  fileprivate let strippedBytes: [Data]

  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.ownerID == rhs.ownerID
  }

  public func hash(into hasher: inout Hasher) {
    hasher.combine(ownerID)
  }
}

public enum InlineTinyThumbnailPrewarmer {
  public static func prewarm(photoInfo: PhotoInfo?) {
    prewarm(strippedBytes: InlineTinyThumbnailDecoder.strippedBytes(from: photoInfo))
  }

  public static func prewarm(strippedBytes: Data?) {
    guard let normalizedBytes = strippedBytes.flatMap({ $0.isEmpty ? nil : $0 }) else { return }
    TinyThumbnailRenderer.prewarm(strippedBytes: normalizedBytes)
  }

  public static func beginWarmup(
    for messages: [FullMessage],
    includeSupportingMedia: Bool,
    priority: InlineTinyThumbnailWarmupPriority
  ) async -> InlineTinyThumbnailWarmup {
    await beginWarmup(
      strippedBytes: strippedBytes(
        for: messages,
        includeSupportingMedia: includeSupportingMedia
      ),
      priority: priority
    )
  }

  public static func beginWarmup(
    strippedBytes: [Data],
    priority: InlineTinyThumbnailWarmupPriority
  ) async -> InlineTinyThumbnailWarmup {
    let normalizedBytes = uniqueBytes(strippedBytes)
    let ownerID = UUID()
    await TinyThumbnailRenderer.prewarm(
      strippedBytes: normalizedBytes,
      priority: priority.renderPriority,
      ownerID: ownerID
    )
    return InlineTinyThumbnailWarmup(ownerID: ownerID, strippedBytes: normalizedBytes)
  }

  public static func waitUntilReady(
    _ warmup: InlineTinyThumbnailWarmup,
    timeout: Duration
  ) async -> Bool {
    if isReady(warmup) { return true }

    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)

    while clock.now < deadline {
      if Task.isCancelled {
        await cancel(warmup)
        return false
      }

      try? await Task.sleep(for: .milliseconds(1))
      if isReady(warmup) { return true }
    }

    if Task.isCancelled {
      await cancel(warmup)
      return false
    }
    return isReady(warmup)
  }

  public static func cancel(_ warmup: InlineTinyThumbnailWarmup) async {
    await TinyThumbnailRenderer.cancel(ownerID: warmup.ownerID)
  }

  private static func isReady(_ warmup: InlineTinyThumbnailWarmup) -> Bool {
    warmup.strippedBytes.allSatisfy { TinyThumbnailRenderer.cachedImage(for: $0) != nil }
  }

  private static func strippedBytes(
    for messages: [FullMessage],
    includeSupportingMedia: Bool
  ) -> [Data] {
    var bytes: [Data] = []

    // Keep primary media for every row ahead of nested/replied media from any row.
    for message in messages {
      if message.message.isSticker != true,
         let photoBytes = InlineTinyThumbnailDecoder.strippedBytes(from: message.photoInfo) {
        bytes.append(photoBytes)
      }
      if let videoBytes = InlineTinyThumbnailDecoder.strippedBytes(from: message.videoInfo?.thumbnail) {
        bytes.append(videoBytes)
      }
      if let documentBytes = InlineTinyThumbnailDecoder.strippedBytes(from: message.documentInfo?.thumbnail) {
        bytes.append(documentBytes)
      }
    }

    guard includeSupportingMedia else { return uniqueBytes(bytes) }

    for message in messages {
      if let replyPhotoBytes = InlineTinyThumbnailDecoder.strippedBytes(from: message.repliedToMessage?.photoInfo) {
        bytes.append(replyPhotoBytes)
      }
      if let replyVideoBytes = InlineTinyThumbnailDecoder.strippedBytes(
        from: message.repliedToMessage?.videoInfo?.thumbnail
      ) {
        bytes.append(replyVideoBytes)
      }

      for attachment in message.attachments {
        if let attachmentBytes = InlineTinyThumbnailDecoder.strippedBytes(from: attachment.photoInfo) {
          bytes.append(attachmentBytes)
        }
        if let authorBytes = InlineTinyThumbnailDecoder.strippedBytes(from: attachment.authorPhotoInfo) {
          bytes.append(authorBytes)
        }
      }
    }

    return uniqueBytes(bytes)
  }

  private static func uniqueBytes(_ bytes: [Data]) -> [Data] {
    var seen = Set<Data>()
    return bytes.filter { !$0.isEmpty && seen.insert($0).inserted }
  }
}

private enum TinyThumbnailRenderConstants {
  static let renderSize = CGSize(width: 48, height: 48)
  static let blurRadius: Double = 7
  static let saturation: Double = 1.25
}

// CGImage is immutable; this wrapper only transports the same rendered value between executors.
private final class TinyThumbnailRenderedImage: @unchecked Sendable {
  let image: CGImage

  init(_ image: CGImage) {
    self.image = image
  }
}

// NSCache synchronizes concurrent reads/writes; no other mutable state escapes this wrapper.
private final class TinyThumbnailImageCache: @unchecked Sendable {
  private let cache: NSCache<NSData, TinyThumbnailRenderedImage> = {
    let cache = NSCache<NSData, TinyThumbnailRenderedImage>()
    cache.countLimit = 512
    return cache
  }()

  func image(for strippedBytes: Data) -> TinyThumbnailRenderedImage? {
    cache.object(forKey: strippedBytes as NSData)
  }

  func setImage(_ image: TinyThumbnailRenderedImage, for strippedBytes: Data) {
    cache.setObject(image, forKey: strippedBytes as NSData)
  }
}

// The lock only coordinates cancellation with actor-side waiter registration.
private final class TinyThumbnailWaiterCancellation: @unchecked Sendable {
  private let lock = NSLock()
  private var cancelled = false

  var isCancelled: Bool {
    lock.lock()
    defer { lock.unlock() }
    return cancelled
  }

  func cancel() {
    lock.lock()
    cancelled = true
    lock.unlock()
  }
}

enum TinyThumbnailRenderPriority: Int, Comparable, Sendable {
  case speculative
  case nearby
  case visible

  static func < (lhs: Self, rhs: Self) -> Bool {
    lhs.rawValue < rhs.rawValue
  }

  var label: StaticString {
    switch self {
      case .speculative: "speculative"
      case .nearby: "nearby"
      case .visible: "visible"
    }
  }

  var dispatchQoS: DispatchQoS {
    switch self {
      case .speculative, .nearby: .utility
      case .visible: .userInitiated
    }
  }
}

actor TinyThumbnailRenderScheduler<Key: Hashable & Sendable, Value: Sendable> {
  typealias CachedValue = @Sendable (Key) -> Value?
  typealias Render = @Sendable (Key, TinyThumbnailRenderPriority, UInt64) async -> Value?

  private enum State: Equatable {
    case queued
    case rendering
  }

  private struct Job {
    var priority: TinyThumbnailRenderPriority
    let sequence: UInt64
    let enqueuedAt: UInt64
    var owners: Set<UUID>
    var waiters: [UUID: CheckedContinuation<Value?, Never>]
    var state: State
  }

  private let maxQueuedSpeculativeJobs: Int
  private let cachedValue: CachedValue
  private let render: Render
  private var jobs: [Key: Job] = [:]
  private var nextSequence: UInt64 = 0
  private var workerTask: Task<Void, Never>?

  init(
    maxQueuedSpeculativeJobs: Int = 48,
    cachedValue: @escaping CachedValue,
    render: @escaping Render
  ) {
    self.maxQueuedSpeculativeJobs = max(maxQueuedSpeculativeJobs, 0)
    self.cachedValue = cachedValue
    self.render = render
  }

  func prewarm(
    keys: [Key],
    priority: TinyThumbnailRenderPriority,
    ownerID: UUID
  ) {
    for key in keys where cachedValue(key) == nil {
      enqueue(key, priority: priority, ownerID: ownerID, waiter: nil)
    }
    trimQueuedSpeculativeJobs()
    startWorkerIfNeeded()
  }

  nonisolated func value(for key: Key, priority: TinyThumbnailRenderPriority) async -> Value? {
    let waiterID = UUID()
    let cancellation = TinyThumbnailWaiterCancellation()

    return await withTaskCancellationHandler {
      await registerWaiter(
        for: key,
        priority: priority,
        waiterID: waiterID,
        cancellation: cancellation
      )
    } onCancel: {
      cancellation.cancel()
      Task {
        await self.cancelWaiter(for: key, waiterID: waiterID)
      }
    }
  }

  private func registerWaiter(
    for key: Key,
    priority: TinyThumbnailRenderPriority,
    waiterID: UUID,
    cancellation: TinyThumbnailWaiterCancellation
  ) async -> Value? {
    guard !cancellation.isCancelled else { return nil }
    if let cached = cachedValue(key) {
      return cached
    }

    return await withCheckedContinuation { continuation in
      guard !cancellation.isCancelled else {
        continuation.resume(returning: nil)
        return
      }

      enqueue(
        key,
        priority: priority,
        ownerID: nil,
        waiter: (waiterID, continuation)
      )
      startWorkerIfNeeded()
    }
  }

  func cancel(ownerID: UUID) {
    for key in Array(jobs.keys) {
      guard var job = jobs[key] else { continue }
      job.owners.remove(ownerID)

      if job.state == .queued, job.owners.isEmpty, job.waiters.isEmpty {
        jobs[key] = nil
      } else {
        jobs[key] = job
      }
    }
  }

  func priority(for key: Key) -> TinyThumbnailRenderPriority? {
    jobs[key]?.priority
  }

  func waitUntilIdle() async {
    while workerTask != nil {
      await Task.yield()
    }
  }

  private func cancelWaiter(for key: Key, waiterID: UUID) {
    guard var job = jobs[key], let waiter = job.waiters.removeValue(forKey: waiterID) else { return }
    waiter.resume(returning: nil)

    if job.state == .queued, job.owners.isEmpty, job.waiters.isEmpty {
      jobs[key] = nil
    } else {
      jobs[key] = job
    }
  }

  private func enqueue(
    _ key: Key,
    priority: TinyThumbnailRenderPriority,
    ownerID: UUID?,
    waiter: (id: UUID, continuation: CheckedContinuation<Value?, Never>)?
  ) {
    if let cached = cachedValue(key) {
      waiter?.continuation.resume(returning: cached)
      return
    }

    if var existing = jobs[key] {
      existing.priority = max(existing.priority, priority)
      if let ownerID {
        existing.owners.insert(ownerID)
      }
      if let waiter {
        existing.waiters[waiter.id] = waiter.continuation
      }
      jobs[key] = existing
      return
    }

    nextSequence &+= 1
    jobs[key] = Job(
      priority: priority,
      sequence: nextSequence,
      enqueuedAt: DispatchTime.now().uptimeNanoseconds,
      owners: ownerID.map { Set([$0]) } ?? [],
      waiters: waiter.map { [$0.id: $0.continuation] } ?? [:],
      state: .queued
    )
  }

  private func trimQueuedSpeculativeJobs() {
    while queuedSpeculativeJobCount > maxQueuedSpeculativeJobs {
      let candidates = jobs.filter { element in
        let job = element.value
        return job.state == .queued && job.priority != .visible && job.waiters.isEmpty
      }
      guard let keyToDrop = candidates.min(by: { lhs, rhs in
        if lhs.value.priority != rhs.value.priority {
          return lhs.value.priority < rhs.value.priority
        }
        return lhs.value.sequence > rhs.value.sequence
      })?.key
      else {
        return
      }
      jobs[keyToDrop] = nil
    }
  }

  private var queuedSpeculativeJobCount: Int {
    jobs.values.count { $0.state == .queued && $0.priority != .visible }
  }

  private func startWorkerIfNeeded() {
    guard workerTask == nil, jobs.values.contains(where: { $0.state == .queued }) else { return }
    workerTask = Task { [weak self] in
      await self?.runWorker()
    }
  }

  private func runWorker() async {
    while let key = nextQueuedKey(), var job = jobs[key] {
      job.state = .rendering
      jobs[key] = job

      let now = DispatchTime.now().uptimeNanoseconds
      let queueWait = now >= job.enqueuedAt ? now - job.enqueuedAt : 0
      let value = await render(key, job.priority, queueWait)

      guard let completed = jobs.removeValue(forKey: key) else { continue }
      for waiter in completed.waiters.values {
        waiter.resume(returning: value)
      }
    }

    workerTask = nil
    startWorkerIfNeeded()
  }

  private func nextQueuedKey() -> Key? {
    var selected: (key: Key, job: Job)?

    for (key, job) in jobs where job.state == .queued {
      guard let current = selected else {
        selected = (key, job)
        continue
      }

      if job.priority > current.job.priority ||
        (job.priority == current.job.priority && job.sequence < current.job.sequence) {
        selected = (key, job)
      }
    }

    return selected?.key
  }
}

private enum TinyThumbnailRenderer {
  private static let imageCache = TinyThumbnailImageCache()
  private static let renderQueue = DispatchQueue(
    label: "InlineTinyThumbnailBackgroundView.renderQueue",
    autoreleaseFrequency: .workItem
  )
  private static let ciContext = CIContext()
  private static let signpostLog = OSLog(subsystem: "InlineUI", category: "PointsOfInterest")
  private static let renderCoordinator = TinyThumbnailRenderScheduler<Data, TinyThumbnailRenderedImage>(
    cachedValue: { imageCache.image(for: $0) },
    render: { strippedBytes, priority, queueWait in
      await renderOnQueue(strippedBytes, priority: priority, queueWaitNanoseconds: queueWait)
    }
  )

  static func cachedImage(for strippedBytes: Data) -> TinyThumbnailRenderedImage? {
    imageCache.image(for: strippedBytes)
  }

  static func prewarm(strippedBytes: Data) {
    guard cachedImage(for: strippedBytes) == nil else { return }

    Task(priority: .utility) {
      await prewarm(
        strippedBytes: [strippedBytes],
        priority: .speculative,
        ownerID: UUID()
      )
    }
  }

  static func prewarm(
    strippedBytes: [Data],
    priority: TinyThumbnailRenderPriority,
    ownerID: UUID
  ) async {
    await renderCoordinator.prewarm(keys: strippedBytes, priority: priority, ownerID: ownerID)
  }

  static func cancel(ownerID: UUID) async {
    await renderCoordinator.cancel(ownerID: ownerID)
  }

  static func prepare(strippedBytes: Data) async -> TinyThumbnailRenderedImage? {
    await renderCoordinator.value(for: strippedBytes, priority: .visible)
  }

  static func renderOnQueue(
    _ strippedBytes: Data,
    priority: TinyThumbnailRenderPriority,
    queueWaitNanoseconds: UInt64
  ) async -> TinyThumbnailRenderedImage? {
    await withCheckedContinuation { continuation in
      let workItem = DispatchWorkItem(qos: priority.dispatchQoS, flags: .enforceQoS) {
        continuation.resume(returning: backgroundImage(
          for: strippedBytes,
          priority: priority,
          queueWaitNanoseconds: queueWaitNanoseconds
        ))
      }
      renderQueue.async(execute: workItem)
    }
  }

  private static func backgroundImage(
    for strippedBytes: Data,
    priority: TinyThumbnailRenderPriority,
    queueWaitNanoseconds: UInt64
  ) -> TinyThumbnailRenderedImage? {
    if let cached = imageCache.image(for: strippedBytes) {
      return cached
    }

    let signpostID = OSSignpostID(log: signpostLog)
    var rendered = false
    os_signpost(
      .begin,
      log: signpostLog,
      name: "TinyThumbnailRender",
      signpostID: signpostID,
      "%{public}s",
      "bytes=\(strippedBytes.count) priority=\(priority.label) queue_wait_ms=\(Double(queueWaitNanoseconds) / 1_000_000)"
    )
    defer {
      os_signpost(
        .end,
        log: signpostLog,
        name: "TinyThumbnailRender",
        signpostID: signpostID,
        "%{public}s",
        "rendered=\(rendered)"
      )
    }

    guard let decodedJPEG = InlineTinyThumbnailDecoder.decodeJPEGData(from: strippedBytes),
          let imageSource = CGImageSourceCreateWithData(decodedJPEG as CFData, nil),
          let decodedImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil),
          let backgroundCGImage = renderBackgroundCGImage(from: decodedImage)
    else {
      return nil
    }

    let image = TinyThumbnailRenderedImage(backgroundCGImage)
    imageCache.setImage(image, for: strippedBytes)
    rendered = true
    return image
  }

  static func recordBind(cacheHit: Bool) {
    os_signpost(
      .event,
      log: signpostLog,
      name: "TinyThumbnailBind",
      "%{public}s",
      cacheHit ? "cache_hit=true" : "cache_hit=false"
    )
  }

  private static func renderBackgroundCGImage(from image: CGImage) -> CGImage? {
    guard let scaledImage = aspectFilledCGImage(from: image, targetSize: TinyThumbnailRenderConstants.renderSize) else {
      return nil
    }

    let inputImage = CIImage(cgImage: scaledImage)
    let blurFilter = CIFilter(name: "CIGaussianBlur")
    blurFilter?.setValue(inputImage.clampedToExtent(), forKey: kCIInputImageKey)
    blurFilter?.setValue(TinyThumbnailRenderConstants.blurRadius, forKey: kCIInputRadiusKey)

    let saturationFilter = CIFilter(name: "CIColorControls")
    saturationFilter?.setValue(blurFilter?.outputImage, forKey: kCIInputImageKey)
    saturationFilter?.setValue(TinyThumbnailRenderConstants.saturation, forKey: kCIInputSaturationKey)

    guard let outputImage = saturationFilter?.outputImage?.cropped(to: inputImage.extent) else {
      return scaledImage
    }

    return ciContext.createCGImage(outputImage, from: inputImage.extent) ?? scaledImage
  }

  private static func aspectFilledCGImage(from image: CGImage, targetSize: CGSize) -> CGImage? {
    let pixelWidth = max(Int(targetSize.width.rounded(.up)), 1)
    let pixelHeight = max(Int(targetSize.height.rounded(.up)), 1)

    guard let context = CGContext(
      data: nil,
      width: pixelWidth,
      height: pixelHeight,
      bitsPerComponent: 8,
      bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
      return nil
    }

    context.interpolationQuality = .high

    let scale = max(
      CGFloat(pixelWidth) / CGFloat(max(image.width, 1)),
      CGFloat(pixelHeight) / CGFloat(max(image.height, 1))
    )
    let drawSize = CGSize(
      width: CGFloat(image.width) * scale,
      height: CGFloat(image.height) * scale
    )
    let drawRect = CGRect(
      x: (CGFloat(pixelWidth) - drawSize.width) / 2,
      y: (CGFloat(pixelHeight) - drawSize.height) / 2,
      width: drawSize.width,
      height: drawSize.height
    )

    context.draw(image, in: drawRect)
    return context.makeImage()
  }
}

public final class InlineTinyThumbnailBackgroundView: PlatformView {
  public var onVisibilityChange: ((Bool) -> Void)? {
    didSet {
      onVisibilityChange?(isShowingThumbnail)
    }
  }
  public var isShowingThumbnail: Bool { !isHidden }

  private let imageView = TinyThumbnailImageView(frame: .zero)
  private var currentBytes: Data?
  private var renderGeneration = 0
  private var renderTask: Task<Void, Never>?

  deinit {
    renderTask?.cancel()
  }

  public convenience init() {
    self.init(frame: .zero)
  }

  public override init(frame: CGRect) {
    super.init(frame: frame)
    setupView()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  public func setPhoto(_ photoInfo: PhotoInfo?) {
    setStrippedBytes(InlineTinyThumbnailDecoder.strippedBytes(from: photoInfo))
  }

  public static func prewarm(photoInfo: PhotoInfo?) {
    InlineTinyThumbnailPrewarmer.prewarm(photoInfo: photoInfo)
  }

  public static func prewarm(strippedBytes: Data?) {
    InlineTinyThumbnailPrewarmer.prewarm(strippedBytes: strippedBytes)
  }

  public func setStrippedBytes(_ strippedBytes: Data?) {
    let normalizedBytes = strippedBytes.flatMap { $0.isEmpty ? nil : $0 }
    guard currentBytes != normalizedBytes else { return }
    currentBytes = normalizedBytes
    renderGeneration += 1
    renderTask?.cancel()

    guard let normalizedBytes else {
      imageView.setImage(nil)
      setThumbnailVisible(false)
      return
    }

    if let cached = TinyThumbnailRenderer.cachedImage(for: normalizedBytes) {
      TinyThumbnailRenderer.recordBind(cacheHit: true)
      imageView.setImage(cached.image)
      setThumbnailVisible(true)
      return
    }

    TinyThumbnailRenderer.recordBind(cacheHit: false)
    imageView.setImage(nil)
    setThumbnailVisible(false)

    let generation = renderGeneration
    renderTask = Task { [weak self] in
      guard let rendered = await TinyThumbnailRenderer.prepare(strippedBytes: normalizedBytes) else { return }
      guard !Task.isCancelled else { return }
      await MainActor.run { [weak self] in
        guard let self,
              self.renderGeneration == generation,
              self.currentBytes == normalizedBytes
        else { return }

        self.imageView.setImage(rendered.image)
        self.setThumbnailVisible(true)
      }
    }
  }

  private func setThumbnailVisible(_ isVisible: Bool) {
    let shouldHide = !isVisible
    guard isHidden != shouldHide else { return }
    isHidden = shouldHide
    onVisibilityChange?(isVisible)
  }

  private func setupView() {
    #if os(macOS)
    wantsLayer = true
    layer?.masksToBounds = true
    #else
    layer.masksToBounds = true
    #endif
    translatesAutoresizingMaskIntoConstraints = false
    isHidden = true

    #if os(iOS)
    isUserInteractionEnabled = false
    #endif

    imageView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(imageView)

    NSLayoutConstraint.activate([
      imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
      imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
      imageView.topAnchor.constraint(equalTo: topAnchor),
      imageView.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
  }
}

#if os(iOS)
private final class TinyThumbnailImageView: UIImageView {
  override init(frame: CGRect) {
    super.init(frame: frame)
    clipsToBounds = true
    contentMode = .scaleAspectFill
    alpha = 0.95
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func setImage(_ image: CGImage?) {
    self.image = image.map { UIImage(cgImage: $0) }
  }
}
#else
private final class TinyThumbnailImageView: NSView {
  private let imageLayer = CALayer()

  convenience init() {
    self.init(frame: .zero)
  }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layer?.masksToBounds = true
    layer?.addSublayer(imageLayer)
    imageLayer.contentsGravity = .resizeAspectFill
    imageLayer.opacity = 0.95
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func layout() {
    super.layout()
    imageLayer.frame = bounds
  }

  override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    imageLayer.contentsScale = window?.backingScaleFactor ?? 2.0
  }

  func setImage(_ image: CGImage?) {
    imageLayer.contents = image
  }
}
#endif
