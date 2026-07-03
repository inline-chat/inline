import UIKit

extension UIView {
  func sendAnimationSnapshotView(
    in rect: CGRect? = nil,
    renderedImage: Bool = false
  ) -> UIView? {
    layoutIfNeeded()

    let snapshotRect = rect ?? bounds
    guard snapshotRect.isFiniteAndVisible else { return nil }

    if renderedImage {
      return sendAnimationRenderedSnapshotView(in: snapshotRect)
    }

    if snapshotRect.equalTo(bounds),
       let snapshotView = snapshotView(afterScreenUpdates: false) {
      return configuredSendAnimationSnapshotView(
        snapshotView,
        frame: CGRect(origin: .zero, size: snapshotRect.size)
      )
    }

    if let snapshotView = resizableSnapshotView(
      from: snapshotRect,
      afterScreenUpdates: false,
      withCapInsets: .zero
    ) {
      return configuredSendAnimationSnapshotView(
        snapshotView,
        frame: CGRect(origin: .zero, size: snapshotRect.size)
      )
    }

    return sendAnimationRenderedSnapshotView(in: snapshotRect)
  }

  func sendAnimationLayerSnapshotView(
    in rect: CGRect? = nil,
    debugName: String? = nil
  ) -> UIView? {
    layoutIfNeeded()

    let snapshotRect = rect ?? bounds
    guard snapshotRect.isFiniteAndVisible else { return nil }

    let renderer = UIGraphicsImageRenderer(
      size: snapshotRect.size,
      format: sendAnimationRendererFormat()
    )
    let image = renderer.image { context in
      context.cgContext.translateBy(x: -snapshotRect.minX, y: -snapshotRect.minY)
      layer.render(in: context.cgContext)
    }

    #if DEBUG || DEBUG_BUILD
      if let debugName,
         let alphaSample = image.sendAnimationVisibleAlphaSample() {
        SendMessageAnimationDiagnostics.debug(
          "snapshot layer-render name=\(debugName) view=\(type(of: self)) rect=[\(SendMessageAnimationDiagnostics.rect(snapshotRect))] image=[\(SendMessageAnimationDiagnostics.size(image.size))] alphaPct=\(String(format: "%.1f", alphaSample.coverage * 100)) visible=\(alphaSample.visible)/\(alphaSample.total)"
        )
      }
    #endif

    let imageView = UIImageView(image: image)
    return configuredSendAnimationSnapshotView(
      imageView,
      frame: CGRect(origin: .zero, size: snapshotRect.size)
    )
  }

  private func sendAnimationRenderedSnapshotView(in snapshotRect: CGRect) -> UIView {
    let renderer = UIGraphicsImageRenderer(
      size: snapshotRect.size,
      format: sendAnimationRendererFormat()
    )
    let image = renderer.image { context in
      context.cgContext.clip(to: CGRect(origin: .zero, size: snapshotRect.size))
      drawHierarchy(
        in: CGRect(
          x: -snapshotRect.minX,
          y: -snapshotRect.minY,
          width: bounds.width,
          height: bounds.height
        ),
        afterScreenUpdates: false
      )
    }
    let imageView = UIImageView(image: image)
    return configuredSendAnimationSnapshotView(
      imageView,
      frame: CGRect(origin: .zero, size: snapshotRect.size)
    )
  }

  private func configuredSendAnimationSnapshotView(
    _ snapshotView: UIView,
    frame: CGRect
  ) -> UIView {
    snapshotView.frame = frame
    snapshotView.backgroundColor = .clear
    snapshotView.isOpaque = false
    snapshotView.isUserInteractionEnabled = false
    return snapshotView
  }

  private func sendAnimationRendererFormat() -> UIGraphicsImageRendererFormat {
    let format = UIGraphicsImageRendererFormat.default()
    format.opaque = false
    format.scale = window?.screen.scale ?? UIScreen.main.scale
    return format
  }
}

extension UIImage {
  func sendAnimationVisibleAlphaSample() -> (visible: Int, total: Int, coverage: CGFloat)? {
    guard let cgImage else { return nil }

    let width = max(1, min(24, Int(size.width.rounded(.up))))
    let height = max(1, min(24, Int(size.height.rounded(.up))))
    let bytesPerPixel = 4
    let bytesPerRow = width * bytesPerPixel
    var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)

    let drewImage = pixels.withUnsafeMutableBytes { buffer -> Bool in
      guard let baseAddress = buffer.baseAddress,
            let context = CGContext(
              data: baseAddress,
              width: width,
              height: height,
              bitsPerComponent: 8,
              bytesPerRow: bytesPerRow,
              space: CGColorSpaceCreateDeviceRGB(),
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
      else {
        return false
      }

      context.interpolationQuality = .low
      context.clear(CGRect(x: 0, y: 0, width: width, height: height))
      context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
      return true
    }
    guard drewImage else { return nil }

    var visible = 0
    for alphaIndex in stride(from: 3, to: pixels.count, by: bytesPerPixel) where pixels[alphaIndex] > 4 {
      visible += 1
    }

    let total = width * height
    guard total > 0 else { return nil }
    return (visible, total, CGFloat(visible) / CGFloat(total))
  }
}
