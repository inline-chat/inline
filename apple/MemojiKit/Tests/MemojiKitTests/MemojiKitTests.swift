import Foundation
import ImageIO
@testable import MemojiKit
import ObjectiveC.runtime
import Testing

@objcMembers
private final class MemojiRuntimeContractFixture: NSObject {
  dynamic func object(at _: UInt) -> AnyObject? { nil }
  dynamic func setEnabled(_: Bool) {}
  dynamic func render(size _: CGSize, scale _: CGFloat, options _: NSDictionary?) -> AnyObject? { nil }
}

@Suite("MemojiKit value API")
struct MemojiKitTests {
  @Test("Background presets have stable unique identifiers and valid channels")
  func backgroundPresets() {
    let styles = MemojiBackgroundStyle.presets

    #expect(styles.count == 13)
    #expect(Set(styles.map(\.id)).count == styles.count)

    for style in styles {
      for color in [style.topColor, style.bottomColor] {
        #expect((0 ... 1).contains(color.red))
        #expect((0 ... 1).contains(color.green))
        #expect((0 ... 1).contains(color.blue))
        #expect((0 ... 1).contains(color.alpha))
      }
    }
    #expect(styles.last?.isTransparent == true)
  }

  @Test("A saved Memoji can become an upload-ready default photo")
  func defaultPhoto() {
    let data = Data([0x89, 0x50, 0x4E, 0x47])
    let memoji = Memoji(id: "saved-record", previewPNGData: data)
    let photo = MemojiPhoto(memoji: memoji)

    #expect(photo.id == memoji.id)
    #expect(photo.memojiID == memoji.id)
    #expect(photo.poseID == nil)
    #expect(photo.backgroundID == nil)
    #expect(photo.pngData == data)
    #expect(memoji.kind == .saved)
  }

  @Test("Objective-C contracts reject ABI drift before invocation")
  func objectiveCMethodContracts() throws {
    let fixtureType = MemojiRuntimeContractFixture.self
    let objectMethod = try #require(
      class_getInstanceMethod(fixtureType, #selector(MemojiRuntimeContractFixture.object(at:)))
    )
    let setterMethod = try #require(
      class_getInstanceMethod(fixtureType, #selector(MemojiRuntimeContractFixture.setEnabled(_:)))
    )
    let renderMethod = try #require(
      class_getInstanceMethod(
        fixtureType,
        #selector(MemojiRuntimeContractFixture.render(size:scale:options:))
      )
    )

    #expect(
      MemojiObjectiveCMethodContract(
        returnValue: .object,
        arguments: [.unsignedInteger]
      ).matches(objectMethod)
    )
    #expect(
      MemojiObjectiveCMethodContract(
        returnValue: .void,
        arguments: [.bool]
      ).matches(setterMethod)
    )
    #expect(
      MemojiObjectiveCMethodContract(
        returnValue: .object,
        arguments: [.size, .cgFloat, .object]
      ).matches(renderMethod)
    )
    #expect(
      !MemojiObjectiveCMethodContract(
        returnValue: .void,
        arguments: [.object]
      ).matches(objectMethod)
    )
  }

  @Test("Diagnostics do not expose saved record identifiers")
  func diagnosticsRedactRecordIdentifiers() {
    let privateIdentifier = "private-avatar-record"
    let error = MemojiError.memojiNotFound(privateIdentifier)

    #expect(error.diagnosticCode == .memojiNotFound)
    #expect(!error.diagnosticSummary.contains(privateIdentifier))
    #expect(!(error.errorDescription ?? "").contains(privateIdentifier))
  }

  @Test("Emoji photos and crop transforms remain square upload-ready PNGs")
  func emojiAndCropRendering() throws {
    let photo = try EmojiProfilePhotoRenderer.render(
      emoji: "👋",
      outputDimension: 128
    )
    #expect(imageDimensions(photo.pngData) == CGSize(width: 128, height: 128))

    let cropped = try MemojiPhotoRenderer.crop(
      photo,
      scale: 1.8,
      horizontalOffset: 0.15,
      verticalOffset: -0.12,
      outputDimension: 96
    )
    #expect(imageDimensions(cropped.pngData) == CGSize(width: 96, height: 96))
    #expect(cropped.id == photo.id)
    #expect(cropped.memojiID == photo.memojiID)

    let transparent = try EmojiProfilePhotoRenderer.render(
      emoji: "👋",
      background: try #require(MemojiBackgroundStyle.presets.last),
      outputDimension: 64
    )
    #expect(cornerAlpha(transparent.pngData) == 0)
    let transparentCrop = try MemojiPhotoRenderer.crop(
      transparent,
      scale: 2,
      horizontalOffset: 0.1,
      verticalOffset: -0.1,
      outputDimension: 48
    )
    #expect(cornerAlpha(transparentCrop.pngData) == 0)
  }

  #if os(macOS)
  @MainActor
  @Test("The current macOS host satisfies the required private runtime contract")
  func currentHostRuntimeContract() {
    let availability = SystemMemojiLibrary.availability

    #expect(availability.isAvailable, Comment(rawValue: availability.detail))
  }

  @MainActor
  @Test("The current macOS host exposes stock Animoji as a fail-soft extension")
  func currentHostStockAnimoji() async throws {
    let library = SystemMemojiLibrary(domainIdentifier: "MemojiKitTests")
    let saved = try library.loadSavedMemoji()
    #expect(saved.allSatisfy { $0.kind == .saved })
    #expect(saved.prefix(3).allSatisfy { cornerAlpha($0.previewPNGData) == 0 })

    var progressivelyLoadedIDs: [Memoji.ID] = []
    let stockItems = try await library.loadStockAnimoji { item in
      progressivelyLoadedIDs.append(item.id)
    }
    #expect(progressivelyLoadedIDs == stockItems.map(\.id))

    let items = try library.loadMemoji()
    let stock = try #require(items.first(where: { $0.kind == .stockAnimoji }))

    #expect(stock.id.hasPrefix("stock::"))
    #expect(cornerAlpha(stock.previewPNGData) == 0)
    let poses = try await library.loadPoses(for: stock, limit: 1)
    #expect(poses.count == 1)
  }
  #endif

  private func imageDimensions(_ data: Data) -> CGSize? {
    guard
      let source = CGImageSourceCreateWithData(data as CFData, nil),
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
        as? [CFString: Any],
      let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
      let height = properties[kCGImagePropertyPixelHeight] as? CGFloat
    else { return nil }
    return CGSize(width: width, height: height)
  }

  private func cornerAlpha(_ data: Data) -> UInt8? {
    guard
      let source = CGImageSourceCreateWithData(data as CFData, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { return nil }

    var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
    guard let context = CGContext(
      data: &pixels,
      width: image.width,
      height: image.height,
      bitsPerComponent: 8,
      bytesPerRow: image.width * 4,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return pixels[3]
  }
}
