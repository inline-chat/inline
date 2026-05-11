import CoreImage
import Foundation
import ImageIO
import InlineKit
import os.signpost

#if os(iOS)
import UIKit
private typealias TinyThumbnailPlatformImage = UIImage
#else
import AppKit
private typealias TinyThumbnailPlatformImage = NSImage
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

public final class InlineTinyThumbnailBackgroundView: PlatformView {
  private enum Constants {
    static let renderSize = CGSize(width: 48, height: 48)
    static let blurRadius: Double = 7
    static let saturation: Double = 1.25
  }

  private static let imageCache: NSCache<NSData, TinyThumbnailPlatformImage> = {
    let cache = NSCache<NSData, TinyThumbnailPlatformImage>()
    cache.countLimit = 512
    return cache
  }()
  private static let ciContext = CIContext()
  private static let signpostLog = OSLog(subsystem: "InlineUI", category: "PointsOfInterest")

  private let imageView = TinyThumbnailImageView(frame: .zero)
  private var currentBytes: Data?

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

  public func setStrippedBytes(_ strippedBytes: Data?) {
    let normalizedBytes = strippedBytes.flatMap { $0.isEmpty ? nil : $0 }
    guard currentBytes != normalizedBytes else { return }
    currentBytes = normalizedBytes

    guard let normalizedBytes,
          let image = Self.backgroundImage(for: normalizedBytes)
    else {
      imageView.setImage(nil as TinyThumbnailPlatformImage?)
      isHidden = true
      return
    }

    imageView.setImage(image)
    isHidden = false
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

  private static func backgroundImage(for strippedBytes: Data) -> TinyThumbnailPlatformImage? {
    let cacheKey = strippedBytes as NSData
    if let cached = imageCache.object(forKey: cacheKey) {
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

    let image = platformImage(from: backgroundCGImage)
    imageCache.setObject(image, forKey: cacheKey)
    rendered = true
    return image
  }

  private static func renderBackgroundCGImage(from image: CGImage) -> CGImage? {
    guard let scaledImage = aspectFilledCGImage(from: image, targetSize: Constants.renderSize) else {
      return nil
    }

    let inputImage = CIImage(cgImage: scaledImage)
    let blurFilter = CIFilter(name: "CIGaussianBlur")
    blurFilter?.setValue(inputImage.clampedToExtent(), forKey: kCIInputImageKey)
    blurFilter?.setValue(Constants.blurRadius, forKey: kCIInputRadiusKey)

    let saturationFilter = CIFilter(name: "CIColorControls")
    saturationFilter?.setValue(blurFilter?.outputImage, forKey: kCIInputImageKey)
    saturationFilter?.setValue(Constants.saturation, forKey: kCIInputSaturationKey)

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

  private static func platformImage(from cgImage: CGImage) -> TinyThumbnailPlatformImage {
    #if os(iOS)
    return UIImage(cgImage: cgImage)
    #else
    return NSImage(
      cgImage: cgImage,
      size: NSSize(width: CGFloat(cgImage.width), height: CGFloat(cgImage.height))
    )
    #endif
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

  func setImage(_ image: UIImage?) {
    self.image = image
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

  func setImage(_ image: NSImage?) {
    imageLayer.contents = image
  }
}
#endif
