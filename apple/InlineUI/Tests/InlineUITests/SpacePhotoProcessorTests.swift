import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import InlineUI

@Suite("Space photo processing")
struct SpacePhotoProcessorTests {
  @Test("invalid images and oversized inputs are rejected")
  func rejectsInvalidInput() {
    #expect(throws: SpacePhotoProcessingError.self) { try SpacePhotoProcessor.prepare(Data([0, 1, 2])) }
    #expect(throws: SpacePhotoProcessingError.self) { try SpacePhotoProcessor.prepare(Data(count: 10 * 1_024 * 1_024 + 1)) }
  }

  @Test("landscape images are normalized to a square PNG")
  func squareCrop() throws {
    let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let context = try #require(CGContext(data: nil, width: 1_600, height: 800, bitsPerComponent: 8, bytesPerRow: 0,
      space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    let image = try #require(context.makeImage())
    let input = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(input, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    let output = try SpacePhotoProcessor.prepare(input as Data)
    let source = try #require(CGImageSourceCreateWithData(output as CFData, nil))
    let result = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    #expect(result.width == result.height)
    #expect(result.width <= 1_024)
    #expect(CGImageSourceGetType(source) as String? == UTType.png.identifier)
  }

  @Test("crop preparation preserves the full landscape and portrait image")
  func preservesEdges() throws {
    for size in [CGSize(width: 800, height: 400), CGSize(width: 400, height: 800)] {
      let image = try fixture(size: size)
      let decoded = try SpacePhotoProcessor.imageForCropping(png(image))
      #expect(decoded.width == Int(size.width))
      #expect(decoded.height == Int(size.height))
    }
  }

  @Test("dragging to each edge keeps the crop inside the image at every zoom")
  func panBounds() {
    for size in [CGSize(width: 800, height: 400), CGSize(width: 400, height: 800)] {
      for zoom: CGFloat in [1, 2, 4] {
        for direction: CGFloat in [-1, 1] {
          let geometry = SpacePhotoCropGeometry(
            imageSize: size, viewport: 280, zoom: zoom,
            offset: CGSize(width: direction * 10_000, height: direction * 10_000)
          )
          let rect = geometry.sourceRect
          #expect(rect.width == rect.height)
          #expect(rect.minX >= -0.0001 && rect.minY >= -0.0001)
          #expect(rect.maxX <= size.width + 0.0001 && rect.maxY <= size.height + 0.0001)
          #expect(abs(rect.width - min(size.width, size.height) / zoom) < 0.0001)
        }
      }
    }
  }

  @Test("zooming out after panning cannot leave an empty border")
  func zoomOutClampsPan() {
    let geometry = SpacePhotoCropGeometry(
      imageSize: CGSize(width: 800, height: 400), viewport: 280, zoom: 0.1,
      offset: CGSize(width: 420, height: -420)
    )
    #expect(geometry.sourceRect == CGRect(x: 0, y: 0, width: 400, height: 400))
    let maxZoom = SpacePhotoCropGeometry(imageSize: CGSize(width: 800, height: 400), viewport: 280, zoom: 10)
    #expect(maxZoom.sourceRect.width == 100)
  }

  @Test("export matches the selected corner, including vertical direction and transparency")
  func exportsSelectedPixels() throws {
    let image = try fixture(size: CGSize(width: 400, height: 400))
    let geometry = SpacePhotoCropGeometry(
      imageSize: CGSize(width: 400, height: 400), viewport: 280, zoom: 2,
      offset: CGSize(width: 140, height: 140)
    )
    #expect(geometry.sourceRect == CGRect(x: 0, y: 0, width: 200, height: 200))
    let data = try SpacePhotoProcessor.crop(image, rect: geometry.sourceRect)
    let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
    let result = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    #expect(result.width == 200 && result.height == 200)
    // The top-left quadrant is red; bottom-left is transparent.
    let pixel = try sample(result)
    #expect(pixel == [255, 0, 0, 255])
    let lower = try SpacePhotoProcessor.crop(image, rect: CGRect(x: 0, y: 200, width: 200, height: 200))
    let lowerSource = try #require(CGImageSourceCreateWithData(lower as CFData, nil))
    let lowerImage = try #require(CGImageSourceCreateImageAtIndex(lowerSource, 0, nil))
    #expect(try sample(lowerImage)[3] == 0)
  }

  @Test("all camera orientations are normalized before cropping", arguments: 1 ... 8)
  func cameraOrientation(_ orientation: Int) throws {
    let image = try fixture(size: CGSize(width: 800, height: 400))
    let data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, [
      kCGImagePropertyOrientation: orientation,
      kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 35.0, kCGImagePropertyGPSLatitudeRef: "N"],
    ] as CFDictionary)
    #expect(CGImageDestinationFinalize(destination))
    let decoded = try SpacePhotoProcessor.imageForCropping(data as Data)
    #expect(decoded.width == (orientation >= 5 ? 400 : 800))
    #expect(decoded.height == (orientation >= 5 ? 800 : 400))
    let exported = try SpacePhotoProcessor.prepare(data as Data)
    let source = try #require(CGImageSourceCreateWithData(exported as CFData, nil))
    let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
    #expect(properties[kCGImagePropertyGPSDictionary] == nil)
    #expect(properties[kCGImagePropertyOrientation] == nil)
  }

  @Test("even one-pixel images can be confirmed at maximum zoom")
  func tinyImages() throws {
    for side in [1, 2, 3] {
      let size = CGSize(width: side, height: side)
      let image = try fixture(size: size)
      let geometry = SpacePhotoCropGeometry(imageSize: size, viewport: 280, zoom: 4)
      let data = try SpacePhotoProcessor.crop(image, rect: geometry.sourceRect)
      let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
      let exported = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
      #expect(exported.width == 1 && exported.height == 1)
    }
  }

  @Test("invalid crop rectangles fail safely instead of trapping during pixel conversion")
  func invalidCropBounds() throws {
    let image = try fixture(size: CGSize(width: 400, height: 400))
    for rect in [
      CGRect.zero, CGRect(x: 0, y: 0, width: 401, height: 401),
      CGRect(x: CGFloat.infinity, y: 0, width: 200, height: 200),
      CGRect(x: 0, y: 0, width: CGFloat.nan, height: 200),
    ] {
      #expect(throws: SpacePhotoProcessingError.self) { try SpacePhotoProcessor.crop(image, rect: rect) }
    }
  }

  private func fixture(size: CGSize) throws -> CGImage {
    let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let context = try #require(CGContext(
      data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
      space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
    context.fill(CGRect(x: 0, y: size.height / 2, width: size.width / 2, height: size.height / 2))
    return try #require(context.makeImage())
  }

  private func png(_ image: CGImage) throws -> Data {
    let data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    return data as Data
  }

  private func sample(_ image: CGImage) throws -> [UInt8] {
    let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let context = try #require(CGContext(
      data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
      space: colorSpace,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
    ))
    context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
    let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
    return Array(UnsafeBufferPointer(start: bytes, count: 4))
  }

}
