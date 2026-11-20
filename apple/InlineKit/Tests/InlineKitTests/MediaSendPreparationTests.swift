import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import InlineKit

@Suite("Media send preparation")
struct MediaSendPreparationTests {
  @Test("a camera photo is sized to 1600, turned upright, and keeps nothing identifying")
  func cameraPhoto() throws {
    // Stored 4000×3000 with orientation 6: shown as 3000×4000 (portrait).
    let source = try makeJPEG(width: 4000, height: 3000, orientation: 6, camera: true, gps: true)

    let prepared = try MediaSendPreparation.preparePhoto(.data(source))

    #expect(prepared.content == .camera)
    #expect(prepared.format == .jpeg)
    #expect(prepared.width == 1200)
    #expect(prepared.height == 1600)
    let properties = try #require(properties(of: prepared.data))
    #expect(properties[kCGImagePropertyGPSDictionary] == nil)
    let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
    #expect(tiff?[kCGImagePropertyTIFFMake] == nil)
    #expect(tiff?[kCGImagePropertyTIFFModel] == nil)
    #expect((properties[kCGImagePropertyOrientation] as? Int ?? 1) == 1)
    let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
    #expect(exif?[kCGImagePropertyExifDateTimeOriginal] == nil)
  }

  @Test("the prepared file needs no further preparation before upload")
  func preparedIsFinal() throws {
    let source = try makeJPEG(width: 3000, height: 2000, orientation: 1, camera: true, gps: true)
    let sourceURL = try write(source, ext: "jpg")
    defer { try? FileManager.default.removeItem(at: sourceURL) }
    #expect(MediaSendPreparation.photoNeedsPreparation(at: sourceURL))

    let prepared = try MediaSendPreparation.preparePhoto(.file(sourceURL))
    let preparedURL = try write(prepared.data, ext: "jpg")
    defer { try? FileManager.default.removeItem(at: preparedURL) }

    #expect(!MediaSendPreparation.photoNeedsPreparation(at: preparedURL))
  }

  @Test("a screenshot keeps up to 2560 and goes as JPEG when its alpha channel is fully opaque")
  func opaqueScreenshot() throws {
    let source = try makePNG(width: 3456, height: 2234, transparentCorner: false)

    let prepared = try MediaSendPreparation.preparePhoto(.data(source))

    #expect(prepared.content == .graphic)
    #expect(prepared.format == .jpeg)
    #expect(prepared.width == 2560)
    #expect(prepared.height == 1655)
  }

  @Test("an image with see-through pixels stays PNG")
  func transparentImage() throws {
    let source = try makePNG(width: 400, height: 300, transparentCorner: true)

    let prepared = try MediaSendPreparation.preparePhoto(.data(source))

    #expect(prepared.format == .png)
    #expect(prepared.width == 400)
  }

  @Test("small photos are never enlarged")
  func noUpscaling() throws {
    let source = try makeJPEG(width: 800, height: 600, orientation: 1, camera: true, gps: false)

    let prepared = try MediaSendPreparation.preparePhoto(.data(source))

    #expect(prepared.width == 800)
    #expect(prepared.height == 600)
  }

  @Test("a screenshot marker wins over camera details")
  func screenshotComment() {
    let properties: [CFString: Any] = [
      kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Apple"] as [CFString: Any],
      kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "Screenshot"] as [CFString: Any],
    ]
    #expect(MediaSendPreparation.classify(properties) == .graphic)
    #expect(MediaSendPreparation.classify([:]) == .graphic)
    #expect(MediaSendPreparation.classify([
      kCGImagePropertyExifDictionary: [kCGImagePropertyExifFNumber: 1.8] as [CFString: Any],
    ]) == .camera)
  }

  @Test("pixels without a file are prepared like a graphic and resized")
  func pixelsOnly() throws {
    let image = try #require(makeImage(width: 5000, height: 1000, alpha: false))

    let prepared = try MediaSendPreparation.preparePhoto(.cgImage(image))

    #expect(prepared.content == .graphic)
    #expect(prepared.width == 2560)
    #expect(prepared.height == 512)
  }

  @Test("very thin or tiny images go as files")
  func documentRule() {
    #expect(MediaSendPreparation.shouldSendAsDocument(width: 1170, height: 25_000))
    #expect(MediaSendPreparation.shouldSendAsDocument(width: 40, height: 30))
    #expect(!MediaSendPreparation.shouldSendAsDocument(width: 1170, height: 20_000))
    #expect(!MediaSendPreparation.shouldSendAsDocument(width: 40, height: 60))
  }

  @Test("the source extension is read from the bytes")
  func fileExtension() throws {
    #expect(MediaSendPreparation.fileExtension(of: try makePNG(width: 10, height: 10, transparentCorner: false)) == "png")
    let jpeg = try makeJPEG(width: 10, height: 10, orientation: 1, camera: false, gps: false)
    #expect(["jpeg", "jpg"].contains(MediaSendPreparation.fileExtension(of: jpeg) ?? ""))
  }
}

@Suite("Original media store")
struct OriginalMediaStoreTests {
  @Test("keeps, finds and discards the original behind a photo")
  func roundTrip() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("originals-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let media = photoItem(localPath: "\(UUID().uuidString).jpg")
    let source = try write(Data("heic bytes".utf8), ext: "heic")
    defer { try? FileManager.default.removeItem(at: source) }

    try OriginalMediaStore.retain(copyOf: source, fileName: "IMG_4821.HEIC", for: media, in: root)

    let original = try #require(OriginalMediaStore.original(for: media, in: root))
    #expect(original.lastPathComponent == "IMG_4821.HEIC")
    #expect(try Data(contentsOf: original) == Data("heic bytes".utf8))

    OriginalMediaStore.discard(for: media, in: root)
    #expect(OriginalMediaStore.original(for: media, in: root) == nil)
  }

  @Test("sweeps originals from drafts nobody sent")
  func sweep() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("originals-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let media = photoItem(localPath: "\(UUID().uuidString).jpg")
    try OriginalMediaStore.retain(data: Data([1, 2, 3]), fileName: "Photo.jpeg", for: media, in: root)

    OriginalMediaStore.sweep(now: Date(), in: root)
    #expect(OriginalMediaStore.original(for: media, in: root) != nil)

    OriginalMediaStore.sweep(now: Date().addingTimeInterval(OriginalMediaStore.maximumAge + 60), in: root)
    #expect(OriginalMediaStore.original(for: media, in: root) == nil)
  }

  @Test("file names can't escape the folder")
  func safeNames() {
    #expect(OriginalMediaStore.safeFileName("../../etc/passwd") == "passwd")
    #expect(OriginalMediaStore.safeFileName("a:b.jpg") == "a-b.jpg")
    #expect(OriginalMediaStore.safeFileName("..") == "original")
  }

  @Test("only photos and videos can be sent as originals")
  func eligibility() {
    #expect(photoItem(localPath: "a.jpg").canSendAsOriginal)
  }
}

// MARK: - Fixtures

private func photoItem(localPath: String) -> FileMediaItem {
  .photo(PhotoInfo(photo: Photo(photoId: -7, format: .jpeg), sizes: [
    PhotoSize(photoId: -7, type: "f", width: 10, height: 10, localPath: localPath),
  ]))
}

private func properties(of data: Data) -> [CFString: Any]? {
  guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
  return CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
}

private func write(_ data: Data, ext: String) throws -> URL {
  let url = FileManager.default.temporaryDirectory.appendingPathComponent("prep-\(UUID().uuidString).\(ext)")
  try data.write(to: url)
  return url
}

private func makeImage(width: Int, height: Int, alpha: Bool, transparentCorner: Bool = false) -> CGImage? {
  guard let context = CGContext(
    data: nil,
    width: width,
    height: height,
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: (alpha ? CGImageAlphaInfo.premultipliedLast : CGImageAlphaInfo.noneSkipLast).rawValue
  ) else {
    return nil
  }
  context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
  context.fill(CGRect(x: 0, y: 0, width: width, height: height))
  context.setFillColor(CGColor(red: 0.9, green: 0.3, blue: 0.1, alpha: 1))
  context.fill(CGRect(x: width / 4, y: height / 4, width: width / 2, height: height / 2))
  if transparentCorner {
    context.clear(CGRect(x: 0, y: 0, width: max(1, width / 10), height: max(1, height / 10)))
  }
  return context.makeImage()
}

private func makeJPEG(width: Int, height: Int, orientation: Int, camera: Bool, gps: Bool) throws -> Data {
  let image = try #require(makeImage(width: width, height: height, alpha: false))
  var properties: [CFString: Any] = [kCGImagePropertyOrientation: orientation]
  if camera {
    properties[kCGImagePropertyTIFFDictionary] = [
      kCGImagePropertyTIFFMake: "Apple",
      kCGImagePropertyTIFFModel: "iPhone 17 Pro",
    ] as [CFString: Any]
    properties[kCGImagePropertyExifDictionary] = [
      kCGImagePropertyExifDateTimeOriginal: "2026:11:20 10:00:00",
      kCGImagePropertyExifFNumber: 1.8,
    ] as [CFString: Any]
  }
  if gps {
    properties[kCGImagePropertyGPSDictionary] = [
      kCGImagePropertyGPSLatitude: 35.7,
      kCGImagePropertyGPSLatitudeRef: "N",
      kCGImagePropertyGPSLongitude: 51.4,
      kCGImagePropertyGPSLongitudeRef: "E",
    ] as [CFString: Any]
  }
  return try encode(image, type: .jpeg, properties: properties)
}

private func makePNG(width: Int, height: Int, transparentCorner: Bool) throws -> Data {
  let image = try #require(makeImage(width: width, height: height, alpha: true, transparentCorner: transparentCorner))
  return try encode(image, type: .png, properties: [:])
}

private func encode(_ image: CGImage, type: UTType, properties: [CFString: Any]) throws -> Data {
  let data = NSMutableData()
  let destination = try #require(CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil))
  CGImageDestinationAddImage(destination, image, properties as CFDictionary)
  #expect(CGImageDestinationFinalize(destination))
  return data as Data
}
