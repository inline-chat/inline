import Foundation
import ImageIO
import Testing

@testable import InlineUI

@Suite("Inline tiny thumbnail decoder")
struct InlineTinyThumbnailDecoderTests {
  @Test("reconstructs JPEG bytes with the shared stripped-thumbnail header/footer")
  func reconstructsJPEGData() {
    let strippedBytes = Data([1, 30, 40, 0xAA, 0xBB, 0xCC])

    let decoded = InlineTinyThumbnailDecoder.decodeJPEGData(from: strippedBytes)

    #expect(decoded != nil)
    guard let decoded else { return }

    #expect(decoded[145] == 0)
    #expect(decoded[146] == 30)
    #expect(decoded[147] == 0)
    #expect(decoded[148] == 40)
    #expect(decoded.suffix(2) == Data([0xFF, 0xD9]))
    #expect(decoded.contains(0xAA))
  }

  @Test("rejects unsupported tiny thumbnail versions")
  func rejectsUnsupportedVersions() {
    let strippedBytes = Data([2, 30, 40, 0xAA, 0xBB, 0xCC])

    let decoded = InlineTinyThumbnailDecoder.decodeJPEGData(from: strippedBytes)

    #expect(decoded == nil)
  }

  @Test("decodes a real stripped payload into a valid JPEG image")
  func decodesRealPayloadIntoImage() {
    let strippedBytes = Data(base64Encoded: "ARkoAAwDAQACEQMRAD8AqUUUV0mAUUUUAFFFFABRRRQAUUUUAFFFFAE=")

    #expect(strippedBytes != nil)
    guard let strippedBytes else { return }

    let decoded = InlineTinyThumbnailDecoder.decodeJPEGData(from: strippedBytes)

    #expect(decoded != nil)
    guard let decoded,
          let imageSource = CGImageSourceCreateWithData(decoded as CFData, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any]
    else {
      Issue.record("Failed to decode stripped thumbnail into a readable JPEG image")
      return
    }

    #expect(properties[kCGImagePropertyPixelWidth] as? Int == 40)
    #expect(properties[kCGImagePropertyPixelHeight] as? Int == 25)
  }
}
