import CoreGraphics
import Foundation
import ImageIO
@preconcurrency import QuickLookThumbnailing
import UniformTypeIdentifiers

public struct DocumentThumbnailer: Sendable {
  public init() {}

  /// Returns whether the current policy admits this file to a thumbnail strategy.
  /// This is an eligibility check only; malformed files and unavailable native
  /// providers can still fail softly during generation.
  public func canAttemptThumbnail(
    for url: URL,
    contentType explicitContentType: UTType? = nil,
    policy: ThumbnailPolicy
  ) -> Bool {
    let contentType = explicitContentType ?? UTType(filenameExtension: url.pathExtension)
    return ThumbnailFormatRegistry.descriptor(
      for: url,
      contentType: contentType,
      policy: policy
    ) != nil
  }

  public func immediateThumbnail(
    for url: URL,
    contentType explicitContentType: UTType? = nil,
    policy: ThumbnailPolicy
  ) -> ThumbnailArtifact? {
    let contentType = resolvedContentType(for: url, explicit: explicitContentType)
    guard let descriptor = ThumbnailFormatRegistry.descriptor(
      for: url,
      contentType: contentType,
      policy: policy
    ) else {
      return nil
    }

    switch descriptor.strategy {
    case .imageIO:
      return ImageThumbnailRenderer.render(url: url, policy: policy, source: .imageIO)
    case let .customFirst(kind), let .quickLookThenCustom(kind):
      guard let rendered = CustomDocumentRenderer.render(kind: kind, at: url) else { return nil }
      return ImageThumbnailRenderer.encode(
        rendered.image,
        maximumPixelSize: policy.maximumPixelSize,
        minimumDimension: policy.minimumDimension,
        source: rendered.source
      )
    case .quickLookOnly:
      return nil
    }
  }

  public func thumbnail(
    for url: URL,
    contentType explicitContentType: UTType? = nil,
    policy: ThumbnailPolicy
  ) async -> ThumbnailArtifact? {
    guard !Task.isCancelled else { return nil }

    let contentType = resolvedContentType(for: url, explicit: explicitContentType)
    guard let descriptor = ThumbnailFormatRegistry.descriptor(
      for: url,
      contentType: contentType,
      policy: policy
    ) else {
      return nil
    }

    switch descriptor.strategy {
    case .imageIO:
      return await renderOffActor {
        ImageThumbnailRenderer.render(url: url, policy: policy, source: .imageIO)
      }
    case let .customFirst(kind):
      if let custom = await renderCustom(kind: kind, url: url, policy: policy) {
        return custom
      }
      return await renderQuickLook(url: url, contentType: contentType, policy: policy)
    case let .quickLookThenCustom(kind):
      if let native = await renderQuickLook(url: url, contentType: contentType, policy: policy) {
        return native
      }
      return await renderCustom(kind: kind, url: url, policy: policy)
    case .quickLookOnly:
      return await renderQuickLook(url: url, contentType: contentType, policy: policy)
    }
  }

  private func resolvedContentType(for url: URL, explicit: UTType?) -> UTType? {
    explicit
      ?? (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)
      ?? UTType(filenameExtension: url.pathExtension)
  }

  private func renderCustom(
    kind: CustomDocumentKind,
    url: URL,
    policy: ThumbnailPolicy
  ) async -> ThumbnailArtifact? {
    await renderOffActor {
      guard let rendered = CustomDocumentRenderer.render(kind: kind, at: url) else { return nil }
      return ImageThumbnailRenderer.encode(
        rendered.image,
        maximumPixelSize: policy.maximumPixelSize,
        minimumDimension: policy.minimumDimension,
        source: rendered.source
      )
    }
  }

  private func renderOffActor(
    _ operation: @escaping @Sendable () -> ThumbnailArtifact?
  ) async -> ThumbnailArtifact? {
    await Task.detached(priority: .utility) {
      guard !Task.isCancelled else { return nil }
      return operation()
    }.value
  }

  private func renderQuickLook(
    url: URL,
    contentType: UTType?,
    policy: ThumbnailPolicy
  ) async -> ThumbnailArtifact? {
    let request = QLThumbnailGenerator.Request(
      fileAt: url,
      size: CGSize(width: policy.maximumPixelSize, height: policy.maximumPixelSize),
      scale: 1,
      representationTypes: [.thumbnail]
    )
    request.contentType = contentType
    request.minimumDimension = CGFloat(policy.minimumDimension)
    request.iconMode = false

    let box = QuickLookRequestBox(request: request)
    let gate = ThumbnailContinuationGate()

    return await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        gate.install(continuation)
        box.generator.generateBestRepresentation(for: request) { representation, _ in
          let artifact: ThumbnailArtifact?
          if let representation, representation.type == .thumbnail {
            artifact = ImageThumbnailRenderer.encode(
              representation.cgImage,
              maximumPixelSize: policy.maximumPixelSize,
              minimumDimension: policy.minimumDimension,
              source: .quickLook
            )
          } else {
            artifact = nil
          }
          gate.resolve(artifact)
        }

        Task.detached(priority: .utility) {
          try? await Task.sleep(for: policy.quickLookTimeout)
          if gate.resolve(nil) {
            box.generator.cancel(box.request)
          }
        }
      }
    } onCancel: {
      if gate.resolve(nil) {
        box.generator.cancel(box.request)
      }
    }
  }
}

private final class QuickLookRequestBox: @unchecked Sendable {
  let generator = QLThumbnailGenerator.shared
  let request: QLThumbnailGenerator.Request

  init(request: QLThumbnailGenerator.Request) {
    self.request = request
  }
}

private final class ThumbnailContinuationGate: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<ThumbnailArtifact?, Never>?
  private var pendingResolution: ThumbnailArtifact??

  func install(_ continuation: CheckedContinuation<ThumbnailArtifact?, Never>) {
    lock.lock()
    if let pendingResolution {
      lock.unlock()
      continuation.resume(returning: pendingResolution)
    } else {
      self.continuation = continuation
      lock.unlock()
    }
  }

  @discardableResult
  func resolve(_ artifact: ThumbnailArtifact?) -> Bool {
    lock.lock()
    guard pendingResolution == nil else {
      lock.unlock()
      return false
    }
    pendingResolution = .some(artifact)
    let continuation = continuation
    self.continuation = nil
    lock.unlock()
    continuation?.resume(returning: artifact)
    return true
  }
}

enum ImageThumbnailRenderer {
  static func render(
    url: URL,
    policy: ThumbnailPolicy,
    source: ThumbnailSource
  ) -> ThumbnailArtifact? {
    let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
    guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else { return nil }
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: policy.maximumPixelSize,
      kCGImageSourceShouldCacheImmediately: true,
    ]
    guard let image = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary) else {
      return nil
    }
    return encode(
      image,
      maximumPixelSize: policy.maximumPixelSize,
      minimumDimension: policy.minimumDimension,
      source: source
    )
  }

  static func encode(
    _ image: CGImage,
    maximumPixelSize: Int,
    minimumDimension: Int,
    source: ThumbnailSource
  ) -> ThumbnailArtifact? {
    guard image.width > 0, image.height > 0, max(image.width, image.height) >= minimumDimension else {
      return nil
    }

    let scale = min(1, CGFloat(maximumPixelSize) / CGFloat(max(image.width, image.height)))
    let width = max(1, Int((CGFloat(image.width) * scale).rounded()))
    let height = max(1, Int((CGFloat(image.height) * scale).rounded()))
    guard let context = CGContext(
      data: nil,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
      return nil
    }

    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    guard let normalized = context.makeImage() else { return nil }

    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(
      data,
      UTType.jpeg.identifier as CFString,
      1,
      nil
    ) else {
      return nil
    }
    let properties = [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary
    CGImageDestinationAddImage(destination, normalized, properties)
    guard CGImageDestinationFinalize(destination) else { return nil }

    return ThumbnailArtifact(
      jpegData: data as Data,
      pixelWidth: width,
      pixelHeight: height,
      source: source
    )
  }
}
