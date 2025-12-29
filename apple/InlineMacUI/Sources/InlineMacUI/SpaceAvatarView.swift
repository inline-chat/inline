import AppKit
import InlineKit

public class SpaceAvatarView: NSView {
  private var space: Space?
  private var size: CGFloat

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
    }
    render()
  }

  private func render() {
    guard let space else {
      imageView.image = nil
      return
    }
    imageView.image = Self.renderImage(for: space, size: size)
  }

  /// Returns an NSImage for the space avatar. Use this when you need an image instead of a view.
  public static func image(for space: Space, size: CGFloat) -> NSImage {
    renderImage(for: space, size: size)
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

private extension Character {
  var isEmoji: Bool {
    guard let scalar = unicodeScalars.first else { return false }
    return scalar.properties.isEmoji && (scalar.value > 0x238C || unicodeScalars.count > 1)
  }
}
