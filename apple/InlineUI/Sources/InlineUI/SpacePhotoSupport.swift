import Auth
import Foundation
import ImageIO
import InlineKit
import UniformTypeIdentifiers

public enum SpacePhotoProcessingError: LocalizedError {
  case invalidImage
  public var errorDescription: String? { "Choose an image smaller than 10 MB." }
}

public enum SpacePhotoProcessor {
  /// Decodes and normalizes orientation without discarding the edges before user cropping.
  public static func imageForCropping(_ data: Data) throws -> CGImage {
    guard data.count <= 10 * 1_024 * 1_024,
          let source = CGImageSourceCreateWithData(data as CFData, nil),
          let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 1_024,
          ] as CFDictionary)
    else { throw SpacePhotoProcessingError.invalidImage }
    return image
  }

  public static func prepare(_ data: Data) throws -> Data {
    let image = try imageForCropping(data)
    return try crop(image, rect: SpacePhotoCropGeometry(
      imageSize: CGSize(width: image.width, height: image.height), viewport: 1
    ).sourceRect)
  }

  public static func crop(_ image: CGImage, rect: CGRect) throws -> Data {
    guard rect.minX.isFinite, rect.minY.isFinite, rect.width.isFinite, rect.height.isFinite,
          rect.width > 0, rect.height > 0,
          rect.width <= CGFloat(image.width), rect.height <= CGFloat(image.height)
    else { throw SpacePhotoProcessingError.invalidImage }
    // A highly zoomed, tiny source still exports its nearest whole pixel.
    let side = max(1, Int(min(rect.width, rect.height).rounded(.down)))
    guard side <= image.width, side <= image.height,
          let cropped = image.cropping(to: CGRect(
            x: min(max(0, rect.minX.rounded()), CGFloat(image.width - side)),
            y: min(max(0, rect.minY.rounded()), CGFloat(image.height - side)),
            width: CGFloat(side), height: CGFloat(side)
          )) else { throw SpacePhotoProcessingError.invalidImage }
    let output = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else {
      throw SpacePhotoProcessingError.invalidImage
    }
    CGImageDestinationAddImage(destination, cropped, nil)
    guard CGImageDestinationFinalize(destination) else { throw SpacePhotoProcessingError.invalidImage }
    return output as Data
  }
}

/// Uses top-left image coordinates, matching SwiftUI's displayed image and ImageIO cropping.
public struct SpacePhotoCropGeometry {
  public let scale: CGFloat
  public let offset: CGSize
  public let displaySize: CGSize
  public let sourceRect: CGRect

  public init(imageSize: CGSize, viewport: CGFloat, zoom: CGFloat = 1, offset: CGSize = .zero) {
    let zoom = min(max(zoom, 1), 4)
    scale = viewport / min(imageSize.width, imageSize.height) * zoom
    displaySize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
    let limitX = max(0, (displaySize.width - viewport) / 2)
    let limitY = max(0, (displaySize.height - viewport) / 2)
    self.offset = CGSize(
      width: min(max(offset.width, -limitX), limitX),
      height: min(max(offset.height, -limitY), limitY)
    )
    let side = viewport / scale
    sourceRect = CGRect(
      x: (imageSize.width - side) / 2 - self.offset.width / scale,
      y: (imageSize.height - side) / 2 - self.offset.height / scale,
      width: side, height: side
    )
  }
}

/// Prepares and persists a photo under one account lease, or removes it when data is nil.
@MainActor
public enum SpacePhotoUpdater {
  public static func update(spaceID: Int64, photoData: Data?) async throws {
    let mutationToken = try Auth.shared.handle.beginAccountMutation()
    let prepared = try await Task.detached(priority: .userInitiated) {
      try photoData.map { try SpacePhotoProcessor.prepare($0) }
    }.value
    try Task.checkCancellation()
    try Auth.shared.handle.validateAccountMutation(mutationToken)
    let fileID: String?
    if let prepared {
      let upload = try await ApiClient.shared.uploadFile(
        type: .photo, data: prepared, filename: "space-photo.png",
        mimeType: .init(text: "image/png"), progress: { _ in }
      )
      fileID = upload.fileUniqueId
    } else {
      fileID = nil
    }
    try Task.checkCancellation()
    try Auth.shared.handle.validateAccountMutation(mutationToken)
    try await InlineRPCClient.shared.setSpacePhoto(
      spaceID: spaceID, fileUniqueID: fileID, accountToken: mutationToken
    )
  }
}
