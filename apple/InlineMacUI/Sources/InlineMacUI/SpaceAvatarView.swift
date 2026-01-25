import AppKit
import GRDB
import InlineKit

public class SpaceAvatarView: NSView {
  private var space: Space?
  private var size: CGFloat
  private var downloadRequestedPhotoId: Int64?

  private lazy var imageView: NSImageView = {
    let view = NSImageView()
    view.imageScaling = .scaleProportionallyUpOrDown
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }()

  public init(space: Space? = nil, size: CGFloat) {
    self.space = space
    self.size = size
    super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
    setupView()
    render()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func setupView() {
    wantsLayer = true
    layer?.cornerRadius = size / 3
    layer?.masksToBounds = true
    translatesAutoresizingMaskIntoConstraints = false
    addSubview(imageView)

    NSLayoutConstraint.activate([
      widthAnchor.constraint(equalToConstant: size),
      heightAnchor.constraint(equalToConstant: size),
      imageView.topAnchor.constraint(equalTo: topAnchor),
      imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
      imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
      imageView.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
  }

  public func configure(space: Space?, size: CGFloat? = nil) {
    self.space = space
    if let size {
      self.size = size
      layer?.cornerRadius = size / 3
    }
    render()
  }

  private func render() {
    guard let space else {
      imageView.image = nil
      return
    }

    if let photoImage = Self.photoImage(for: space, size: size, downloadHandler: requestDownloadIfNeeded) {
      imageView.image = photoImage
      return
    }

    imageView.image = Self.renderImage(for: space, size: size)
  }

  /// Returns an NSImage for the space avatar. Use this when you need an image instead of a view.
  public static func image(for space: Space, size: CGFloat) -> NSImage {
    if let photoImage = photoImage(for: space, size: size, downloadHandler: nil) {
      return photoImage
    }
    return renderImage(for: space, size: size)
  }

  private static func photoImage(
    for space: Space,
    size: CGFloat,
    downloadHandler: ((PhotoInfo) -> Void)?
  ) -> NSImage? {
    guard let photoInfo = photoInfo(for: space) else { return nil }

    if let localUrl = localUrl(for: photoInfo),
       let image = NSImage(contentsOf: localUrl)
    {
      return image
    }

    downloadHandler?(photoInfo)
    return nil
  }

  private static func photoInfo(for space: Space) -> PhotoInfo? {
    guard let photoId = space.photoId else { return nil }

    return try? AppDatabase.shared.dbWriter.read { db in
      try Photo
        .filter(Photo.Columns.photoId == photoId)
        .including(all: Photo.sizes.forKey(PhotoInfo.CodingKeys.sizes))
        .asRequest(of: PhotoInfo.self)
        .fetchOne(db)
    }
  }

  private static func localUrl(for photoInfo: PhotoInfo) -> URL? {
    guard let size = photoInfo.bestPhotoSize(),
          let localPath = size.localPath
    else { return nil }

    let url = FileCache.getUrl(for: .photos, localPath: localPath)
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    return url
  }

  private func requestDownloadIfNeeded(_ photoInfo: PhotoInfo) {
    guard downloadRequestedPhotoId != photoInfo.id else { return }
    downloadRequestedPhotoId = photoInfo.id

    Task { [weak self] in
      await FileCache.shared.download(photo: photoInfo)
      await MainActor.run {
        self?.render()
      }
    }
  }

  private static func renderImage(for space: Space, size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()

    let rect = NSRect(x: 0, y: 0, width: size, height: size)
    let cornerRadius = size / 3
    let path = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
    NSColor.gray.withAlphaComponent(0.15).setFill()
    path.fill()

    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center

    let text: String = {
      if let emoji = leadingEmoji(for: space) {
        return emoji
      }
      let trimmed = space.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.first.map { String($0).uppercased() } ?? "·"
    }()

    let fontScale: CGFloat = text.isAllEmojis ? 0.6 : 0.55
    let attributes: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: size * fontScale, weight: .semibold),
      .foregroundColor: NSColor.secondaryLabelColor,
      .paragraphStyle: paragraph,
    ]

    let attr = NSAttributedString(string: text, attributes: attributes)
    let strSize = attr.size()
    let strRect = NSRect(
      x: (size - strSize.width) / 2,
      y: (size - strSize.height) / 2,
      width: strSize.width,
      height: strSize.height
    )
    attr.draw(in: strRect)

    image.unlockFocus()
    return image
  }

  private static func leadingEmoji(for space: Space) -> String? {
    let rawName = space.name
    let nameWithoutEmoji = space.nameWithoutEmoji
    guard rawName != nameWithoutEmoji else { return nil }
    let emojiPart = nameWithoutEmoji.isEmpty
      ? rawName
      : String(rawName.dropLast(nameWithoutEmoji.count))
    let trimmed = emojiPart.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}

private extension String {
  var isAllEmojis: Bool {
    !isEmpty && allSatisfy { $0.isEmoji }
  }
}
