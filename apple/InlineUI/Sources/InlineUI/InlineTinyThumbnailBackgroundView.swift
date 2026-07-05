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

public enum InlineTinyThumbnailPrewarmer {
  public static func prewarm(photoInfo: PhotoInfo?) {
    prewarm(strippedBytes: InlineTinyThumbnailDecoder.strippedBytes(from: photoInfo))
  }

  public static func prewarm(strippedBytes: Data?) {
    guard let normalizedBytes = strippedBytes.flatMap({ $0.isEmpty ? nil : $0 }) else { return }
    TinyThumbnailRenderer.prewarm(strippedBytes: normalizedBytes)
  }
}

private enum TinyThumbnailRenderConstants {
  static let renderSize = CGSize(width: 48, height: 48)
  static let blurRadius: Double = 7
  static let saturation: Double = 1.25
}

private final class TinyThumbnailRenderedImage: @unchecked Sendable {
  let image: CGImage

  init(_ image: CGImage) {
    self.image = image
  }
}

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

private actor TinyThumbnailRenderCoordinator {
  private var inFlight: [Data: Task<TinyThumbnailRenderedImage?, Never>] = [:]

  func prepare(strippedBytes: Data) async -> TinyThumbnailRenderedImage? {
    if let cached = TinyThumbnailRenderer.cachedImage(for: strippedBytes) {
      return cached
    }

    if let existing = inFlight[strippedBytes] {
      return await existing.value
    }

    let task = Task.detached(priority: .utility) {
      await TinyThumbnailRenderer.renderOnQueue(strippedBytes)
    }
    inFlight[strippedBytes] = task
    let rendered = await task.value
    inFlight[strippedBytes] = nil
    return rendered
  }
}

private enum TinyThumbnailRenderer {
  private static let imageCache = TinyThumbnailImageCache()
  private static let renderQueue = DispatchQueue(
    label: "InlineTinyThumbnailBackgroundView.renderQueue",
    qos: .utility,
    autoreleaseFrequency: .workItem
  )
  private static let renderCoordinator = TinyThumbnailRenderCoordinator()
  private static let ciContext = CIContext()
  private static let signpostLog = OSLog(subsystem: "InlineUI", category: "PointsOfInterest")

  static func cachedImage(for strippedBytes: Data) -> TinyThumbnailRenderedImage? {
    imageCache.image(for: strippedBytes)
  }

  static func prewarm(strippedBytes: Data) {
    guard cachedImage(for: strippedBytes) == nil else { return }

    Task.detached(priority: .utility) {
      _ = await renderCoordinator.prepare(strippedBytes: strippedBytes)
    }
  }

  static func prepare(strippedBytes: Data) async -> TinyThumbnailRenderedImage? {
    await renderCoordinator.prepare(strippedBytes: strippedBytes)
  }

  static func renderOnQueue(_ strippedBytes: Data) async -> TinyThumbnailRenderedImage? {
    await withCheckedContinuation { continuation in
      renderQueue.async {
        continuation.resume(returning: backgroundImage(for: strippedBytes))
      }
    }
  }

  private static func backgroundImage(for strippedBytes: Data) -> TinyThumbnailRenderedImage? {
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
      "bytes=\(strippedBytes.count)"
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
      isHidden = true
      return
    }

    if let cached = TinyThumbnailRenderer.cachedImage(for: normalizedBytes) {
      imageView.setImage(cached.image)
      isHidden = false
      return
    }

    imageView.setImage(nil)
    isHidden = true

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
        self.isHidden = false
      }
    }
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
