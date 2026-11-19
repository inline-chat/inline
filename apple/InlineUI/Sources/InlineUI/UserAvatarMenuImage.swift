#if os(iOS)
import ImageIO
import InlineKit
import Kingfisher
import UIKit

/// Small round avatar photos for menus. A menu needs its images before it shows and can't change
/// them after, so this reads the photo the avatar views already cached (the same key), and only
/// downloads when nothing has it.
@MainActor
public enum UserAvatarMenuImage {
  private static let images = NSCache<NSString, UIImage>()

  /// The photo, if it is decoded already or on disk (the avatar views keep each original there);
  /// nil when it has to be downloaded, or the user has no photo.
  public static func cached(for user: User, side: CGFloat, scale: CGFloat) -> UIImage? {
    guard let source = UserAvatarImageSource(user: user, scale: scale) else { return nil }
    let key = cacheKey(source, side: side)
    if let image = images.object(forKey: key) { return image }
    let cachePath = KingfisherManager.shared.cache.cachePath(forKey: source.cacheKey)
    let file = FileManager.default.fileExists(atPath: cachePath)
      ? URL(fileURLWithPath: cachePath)
      : source.url.isFileURL ? source.url : nil
    guard let file, let data = try? Data(contentsOf: file), let image = round(data, side: side, scale: scale) else {
      return nil
    }
    images.setObject(image, forKey: key)
    return image
  }

  /// Whether the user has a photo to show at all, as opposed to initials.
  public static func hasPhoto(_ user: User) -> Bool {
    UserAvatarImageSource(user: user) != nil
  }

  /// Loads the photo, downloading it if needed. Gives up after `timeout` so a menu never waits
  /// long; the download carries on and the next menu shows it.
  public static func load(for user: User, side: CGFloat, scale: CGFloat, timeout: Duration = .seconds(1.5)) async -> UIImage? {
    if let image = cached(for: user, side: side, scale: scale) { return image }
    guard let source = UserAvatarImageSource(user: user, scale: scale) else { return nil }
    let key = cacheKey(source, side: side)
    let race = Race()
    return await withCheckedContinuation { continuation in
      Task { @MainActor in
        let data = try? await source.originalImageData()
        let image = data.flatMap { round($0, side: side, scale: scale) }
        if let image { images.setObject(image, forKey: key) }
        race.finish(continuation, with: image)
      }
      Task { @MainActor in
        try? await Task.sleep(for: timeout)
        race.finish(continuation, with: nil)
      }
    }
  }

  private static func cacheKey(_ source: UserAvatarImageSource, side: CGFloat) -> NSString {
    "\(source.cacheKey):menu\(Int(side))" as NSString
  }

  /// A circle of `side` points, decoded at that size.
  private static func round(_ data: Data, side: CGFloat, scale: CGFloat) -> UIImage? {
    let pixels = side * max(scale, 1)
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: pixels * 2,
    ]
    guard let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
          let thumbnail = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary)
    else { return nil }
    let photo = UIImage(cgImage: thumbnail)
    let format = UIGraphicsImageRendererFormat()
    format.scale = max(scale, 1)
    let rect = CGRect(x: 0, y: 0, width: side, height: side)
    return UIGraphicsImageRenderer(size: rect.size, format: format).image { _ in
      UIBezierPath(ovalIn: rect).addClip()
      // Aspect fill, like the avatar views.
      let ratio = max(side / photo.size.width, side / photo.size.height)
      let size = CGSize(width: photo.size.width * ratio, height: photo.size.height * ratio)
      photo.draw(in: CGRect(x: (side - size.width) / 2, y: (side - size.height) / 2, width: size.width, height: size.height))
    }.withRenderingMode(.alwaysOriginal)
  }

  /// Resumes once: with the photo, or with nil when the timeout comes first.
  @MainActor
  private final class Race {
    private var done = false

    func finish(_ continuation: CheckedContinuation<UIImage?, Never>, with image: UIImage?) {
      guard !done else { return }
      done = true
      continuation.resume(returning: image)
    }
  }
}
#endif
