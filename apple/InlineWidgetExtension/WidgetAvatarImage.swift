import ImageIO
import UIKit

/// Avatars the app exported to the app group, decoded at the size the widget draws them.
/// Widgets have a small memory budget, so images are never decoded at full size.
enum WidgetAvatarImage {
  static func load(_ url: URL?, pointSize: CGFloat, scale: CGFloat = 3) -> UIImage? {
    guard let url,
          let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
    else { return nil }

    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceShouldCacheImmediately: true,
      kCGImageSourceThumbnailMaxPixelSize: Int(pointSize * scale),
    ]
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
      return nil
    }
    return UIImage(cgImage: image)
  }
}
