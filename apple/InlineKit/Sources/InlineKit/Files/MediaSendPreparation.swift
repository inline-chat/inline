import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Turns a picked photo into the bytes Inline sends, the way Telegram's compressed send does:
/// one decode, resized for what the photo is, pixels upright, and no metadata written. Camera
/// photos rarely need more than a full-screen view and are expensive in bytes; screenshots and
/// other graphics need resolution for small text and stay cheap, so each gets its own size.
///
/// Native uploads are published byte for byte, so this is the only place metadata is removed for
/// photos sent from the apps. The prepared file is what gets staged, hashed and uploaded.
public enum MediaSendPreparation {
  /// What a photo shows, which decides how large it is sent.
  public enum PhotoContent: String, Sendable, Equatable {
    /// Taken by a camera: the file names the camera that made it.
    case camera
    /// Screenshots, pasted, exported or downloaded images: no camera recorded in the file.
    case graphic
  }

  public struct PhotoTarget: Sendable, Equatable {
    public let maxPixelSize: Int
    public let jpegQuality: Double
  }

  public static func target(for content: PhotoContent) -> PhotoTarget {
    switch content {
    case .camera: PhotoTarget(maxPixelSize: 1_600, jpegQuality: 0.8)
    case .graphic: PhotoTarget(maxPixelSize: 2_560, jpegQuality: 0.8)
    }
  }

  /// Video thumbnails show in a bubble and the server makes smaller copies from them.
  public static let videoThumbnailTarget = PhotoTarget(maxPixelSize: 1_280, jpegQuality: 0.8)

  /// The longest edge any prepared photo can have. Anything larger was not prepared here.
  static var largestPreparedPixelSize: Int { target(for: .graphic).maxPixelSize }

  public enum PhotoSource: @unchecked Sendable {
    /// A file on disk, read without decoding more than the resized output needs.
    case file(URL)
    /// Encoded image bytes, such as a pasteboard or Photos library representation.
    case data(Data)
    /// Pixels that are already upright and carry no metadata.
    case cgImage(CGImage)
    /// A decoded platform image, drawn upright. Used when no encoded source exists.
    case platformImage(PlatformImage)
  }

  public struct PreparedPhoto: Sendable {
    public let data: Data
    public let format: ImageFormat
    public let width: Int
    public let height: Int
    public let content: PhotoContent
  }

  public enum PreparationError: Error, Equatable {
    case unreadableImage
    case encodeFailed
  }

  /// Prepares a photo for sending. `content` overrides the classification read from the file,
  /// for callers that know better (a camera capture handed over as pixels, for example).
  public static func preparePhoto(
    _ source: PhotoSource,
    content: PhotoContent? = nil,
    target explicitTarget: PhotoTarget? = nil
  ) throws -> PreparedPhoto {
    switch source {
    case let .file(url):
      guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else {
        throw PreparationError.unreadableImage
      }
      return try prepare(imageSource: imageSource, content: content, target: explicitTarget)
    case let .data(data):
      guard let imageSource = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
        throw PreparationError.unreadableImage
      }
      return try prepare(imageSource: imageSource, content: content, target: explicitTarget)
    case let .cgImage(image):
      let resolved = content ?? .graphic
      let target = explicitTarget ?? target(for: resolved)
      let resized = try resize(image, maxPixelSize: target.maxPixelSize)
      return try encode(resized, target: target, content: resolved)
    case let .platformImage(image):
      let resolved = content ?? .graphic
      let target = explicitTarget ?? target(for: resolved)
      guard let upright = renderUpright(image, maxPixelSize: target.maxPixelSize) else {
        throw PreparationError.unreadableImage
      }
      return try encode(upright, target: target, content: resolved)
    }
  }

  /// Reads only the header: whether a photo file still needs preparing before it can be sent.
  /// A file this type prepared is already within size and carries nothing identifying.
  public static func photoNeedsPreparation(at url: URL) -> Bool {
    guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, sourceOptions),
          let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any]
    else {
      return true
    }
    let (width, height) = orientedPixelSize(properties)
    if max(width, height) > largestPreparedPixelSize { return true }
    if let orientation = properties[kCGImagePropertyOrientation] as? Int, orientation != 1 { return true }
    return carriesIdentifyingMetadata(properties)
  }

  /// The format of a prepared photo file, read from its header; nil for anything else.
  public static func preparedFormat(at url: URL) -> ImageFormat? {
    guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, sourceOptions),
          let identifier = CGImageSourceGetType(imageSource) as String?,
          let type = UTType(identifier)
    else {
      return nil
    }
    if type.conforms(to: .png) { return .png }
    if type.conforms(to: .jpeg) { return .jpeg }
    return nil
  }

  /// Full resolution, for an image that goes as a file: a long screenshot must stay readable.
  public static let fileCopyTarget = PhotoTarget(maxPixelSize: 100_000, jpegQuality: 0.92)

  /// An image that goes as a file without Send as Original (too thin or tiny to show as a photo,
  /// or it couldn't be prepared) keeps its own bytes only when they carry nothing identifying.
  /// Otherwise this is a full-resolution copy, upright and without metadata, and it throws rather
  /// than let such an image go untouched. Nil: the image can go as it is (no metadata, or not an
  /// image ImageIO reads, so nothing it could find).
  public static func anonymizedFileCopy(of source: PhotoSource) throws -> PreparedPhoto? {
    let imageSource: CGImageSource? = switch source {
    case let .file(url): CGImageSourceCreateWithURL(url as CFURL, sourceOptions)
    case let .data(data): CGImageSourceCreateWithData(data as CFData, sourceOptions)
    // Pixels carry no metadata.
    case .cgImage, .platformImage: nil
    }
    guard let imageSource,
          let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
          carriesIdentifyingMetadata(properties)
    else {
      return nil
    }
    return try prepare(imageSource: imageSource, content: nil, target: fileCopyTarget)
  }

  /// Images too thin or too tiny to show as a photo are sent as files. The server rejects photos
  /// with an aspect ratio over 20.
  public static func shouldSendAsDocument(width: Int, height: Int) -> Bool {
    let width = max(width, 1), height = max(height, 1)
    let ratio = Double(max(width, height)) / Double(min(width, height))
    return ratio > 20 || (width < 50 && height < 50)
  }

  /// Upright pixel size of a source, read from the header for encoded sources.
  public static func pixelSize(of source: PhotoSource) -> (width: Int, height: Int)? {
    let imageSource: CGImageSource?
    switch source {
    case let .file(url):
      imageSource = CGImageSourceCreateWithURL(url as CFURL, sourceOptions)
    case let .data(data):
      imageSource = CGImageSourceCreateWithData(data as CFData, sourceOptions)
    case let .cgImage(image):
      return (image.width, image.height)
    case let .platformImage(image):
      #if canImport(UIKit)
      return (Int((image.size.width * image.scale).rounded()), Int((image.size.height * image.scale).rounded()))
      #else
      let representation = image.representations.first { $0 is NSBitmapImageRep }
      return (representation?.pixelsWide ?? Int(image.size.width), representation?.pixelsHigh ?? Int(image.size.height))
      #endif
    }
    guard let imageSource,
          let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any]
    else {
      return nil
    }
    let size = orientedPixelSize(properties)
    return size.width > 0 && size.height > 0 ? size : nil
  }

  /// The usual file extension for encoded image bytes ("heic", "jpeg", "png").
  public static func fileExtension(of data: Data) -> String? {
    guard let imageSource = CGImageSourceCreateWithData(data as CFData, sourceOptions),
          let type = CGImageSourceGetType(imageSource)
    else {
      return nil
    }
    return UTType(type as String)?.preferredFilenameExtension
  }

  // MARK: - Classification

  static func classify(_ properties: [CFString: Any]) -> PhotoContent {
    let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
    if let comment = exif?[kCGImagePropertyExifUserComment] as? String,
       comment.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare("Screenshot") == .orderedSame
    {
      return .graphic
    }
    let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
    if nonEmpty(tiff?[kCGImagePropertyTIFFMake]) || nonEmpty(tiff?[kCGImagePropertyTIFFModel]) {
      return .camera
    }
    if nonEmpty(exif?[kCGImagePropertyExifLensModel]) || exif?[kCGImagePropertyExifExposureTime] != nil
      || exif?[kCGImagePropertyExifFNumber] != nil
    {
      return .camera
    }
    return .graphic
  }

  static func carriesIdentifyingMetadata(_ properties: [CFString: Any]) -> Bool {
    if let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any], !gps.isEmpty { return true }
    if let iptc = properties[kCGImagePropertyIPTCDictionary] as? [CFString: Any], !iptc.isEmpty { return true }
    if let apple = properties[kCGImagePropertyMakerAppleDictionary] as? [CFString: Any], !apple.isEmpty { return true }
    let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
    for key in [kCGImagePropertyTIFFMake, kCGImagePropertyTIFFModel, kCGImagePropertyTIFFDateTime,
                kCGImagePropertyTIFFSoftware, kCGImagePropertyTIFFArtist, kCGImagePropertyTIFFHostComputer]
      where nonEmpty(tiff?[key])
    {
      return true
    }
    let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
    for key in [kCGImagePropertyExifDateTimeOriginal, kCGImagePropertyExifDateTimeDigitized,
                kCGImagePropertyExifLensModel, kCGImagePropertyExifBodySerialNumber,
                kCGImagePropertyExifCameraOwnerName, kCGImagePropertyExifUserComment]
      where nonEmpty(exif?[key])
    {
      return true
    }
    return false
  }

  private static func nonEmpty(_ value: Any?) -> Bool {
    guard let value else { return false }
    if let string = value as? String {
      return !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    return true
  }

  // MARK: - Decode and resize

  private static var sourceOptions: CFDictionary { [kCGImageSourceShouldCache: false] as CFDictionary }

  private static func prepare(
    imageSource: CGImageSource,
    content: PhotoContent?,
    target explicitTarget: PhotoTarget?
  ) throws -> PreparedPhoto {
    guard CGImageSourceGetCount(imageSource) > 0 else { throw PreparationError.unreadableImage }
    let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any] ?? [:]
    let resolved = content ?? classify(properties)
    let target = explicitTarget ?? target(for: resolved)
    let (width, height) = orientedPixelSize(properties)
    let longEdge = max(width, height)
    let maxPixelSize = longEdge > 0 ? min(target.maxPixelSize, longEdge) : target.maxPixelSize
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
      kCGImageSourceShouldCacheImmediately: true,
    ]
    guard let image = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary) else {
      throw PreparationError.unreadableImage
    }
    return try encode(image, target: target, content: resolved)
  }

  /// Pixel size with EXIF orientations 5–8 (rotated a quarter turn) swapped.
  static func orientedPixelSize(_ properties: [CFString: Any]) -> (width: Int, height: Int) {
    let width = (properties[kCGImagePropertyPixelWidth] as? Int) ?? 0
    let height = (properties[kCGImagePropertyPixelHeight] as? Int) ?? 0
    let orientation = (properties[kCGImagePropertyOrientation] as? Int) ?? 1
    return orientation >= 5 ? (height, width) : (width, height)
  }

  static func fittedSize(width: Int, height: Int, maxPixelSize: Int) -> (width: Int, height: Int) {
    let longEdge = max(width, height)
    guard longEdge > maxPixelSize, longEdge > 0 else { return (width, height) }
    let scale = Double(maxPixelSize) / Double(longEdge)
    return (max(1, Int((Double(width) * scale).rounded())), max(1, Int((Double(height) * scale).rounded())))
  }

  private static func resize(_ image: CGImage, maxPixelSize: Int) throws -> CGImage {
    let (width, height) = fittedSize(width: image.width, height: image.height, maxPixelSize: maxPixelSize)
    guard width != image.width || height != image.height else { return image }
    guard let context = drawingContext(width: width, height: height, like: image) else {
      throw PreparationError.encodeFailed
    }
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    guard let resized = context.makeImage() else { throw PreparationError.encodeFailed }
    return resized
  }

  private static func drawingContext(width: Int, height: Int, like image: CGImage?) -> CGContext? {
    let colorSpace = image?.colorSpace.flatMap { $0.model == .rgb ? $0 : nil }
      ?? CGColorSpace(name: CGColorSpace.sRGB)!
    return CGContext(
      data: nil,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: 0,
      space: colorSpace,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )
  }

  #if canImport(UIKit)
  private static func renderUpright(_ image: UIImage, maxPixelSize: Int) -> CGImage? {
    let pixelWidth = Int((image.size.width * image.scale).rounded())
    let pixelHeight = Int((image.size.height * image.scale).rounded())
    let (width, height) = fittedSize(width: pixelWidth, height: pixelHeight, maxPixelSize: maxPixelSize)
    if image.imageOrientation == .up, let cgImage = image.cgImage {
      return try? resize(cgImage, maxPixelSize: maxPixelSize)
    }
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = false
    let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format)
    return renderer.image { _ in
      image.draw(in: CGRect(x: 0, y: 0, width: width, height: height))
    }.cgImage
  }
  #elseif canImport(AppKit)
  private static func renderUpright(_ image: NSImage, maxPixelSize: Int) -> CGImage? {
    let representation = image.representations.first { $0 is NSBitmapImageRep }
    let pixelWidth = representation?.pixelsWide ?? Int(image.size.width)
    let pixelHeight = representation?.pixelsHigh ?? Int(image.size.height)
    guard pixelWidth > 0, pixelHeight > 0 else { return nil }
    let (width, height) = fittedSize(width: pixelWidth, height: pixelHeight, maxPixelSize: maxPixelSize)
    let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    guard let context = drawingContext(width: width, height: height, like: source) else { return nil }
    context.interpolationQuality = .high
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    image.draw(in: NSRect(x: 0, y: 0, width: width, height: height), from: .zero, operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    return context.makeImage()
  }
  #endif

  // MARK: - Encode

  /// JPEG unless some pixel is actually see-through. Screenshots often carry an alpha channel
  /// that is fully opaque; sending those as PNG made them several times larger.
  private static func encode(_ image: CGImage, target: PhotoTarget, content: PhotoContent) throws -> PreparedPhoto {
    let format: ImageFormat = hasVisibleTransparency(image) ? .png : .jpeg
    let data = NSMutableData()
    let type = format == .png ? UTType.png.identifier : UTType.jpeg.identifier
    guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, type as CFString, 1, nil) else {
      throw PreparationError.encodeFailed
    }
    // Only the encoder setting is passed: a CGImage carries no metadata, so nothing about the
    // camera, place or time is written. The color profile travels with the image itself.
    let properties: [CFString: Any] = format == .jpeg
      ? [kCGImageDestinationLossyCompressionQuality: target.jpegQuality]
      : [:]
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    guard CGImageDestinationFinalize(destination), data.length > 0 else { throw PreparationError.encodeFailed }
    return PreparedPhoto(data: data as Data, format: format, width: image.width, height: image.height, content: content)
  }

  static func hasVisibleTransparency(_ image: CGImage) -> Bool {
    switch image.alphaInfo {
    case .none, .noneSkipFirst, .noneSkipLast:
      return false
    default:
      break
    }
    let width = image.width, height = image.height
    guard width > 0, height > 0,
          let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue
          )
    else {
      return true
    }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    guard let pixels = context.data else { return true }
    let bytesPerRow = context.bytesPerRow
    let buffer = pixels.bindMemory(to: UInt8.self, capacity: bytesPerRow * height)
    for row in 0 ..< height {
      let start = buffer + row * bytesPerRow
      for column in 0 ..< width where start[column] < 255 {
        return true
      }
    }
    return false
  }
}
