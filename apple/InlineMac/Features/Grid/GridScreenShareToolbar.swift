import AppKit
import Foundation

struct GridScreenShareToolbarIdentity: Equatable {
  let displayName: String
  let firstName: String?
  let lastName: String?
  let localAvatarURL: URL?
  let remoteAvatarURL: URL?
}

@MainActor
final class GridScreenShareTitlebarController: NSTitlebarAccessoryViewController {
  private let identity: GridScreenShareToolbarIdentity

  init(identity: GridScreenShareToolbarIdentity) {
    self.identity = identity
    super.init(nibName: nil, bundle: nil)
    layoutAttribute = .leading
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func loadView() {
    view = GridScreenShareTitlebarIdentityView(identity: identity)
  }
}

@MainActor
private final class GridScreenShareTitlebarIdentityView: NSView {
  override var mouseDownCanMoveWindow: Bool { true }

  init(identity: GridScreenShareToolbarIdentity) {
    let avatar = GridScreenShareToolbarAvatarView(identity: identity, size: 24)
    avatar.translatesAutoresizingMaskIntoConstraints = false
    let title = String(
      localized: "\(identity.displayName)’s screen",
      comment: "Screen-share viewer toolbar title; the variable is the sharer's display name."
    )
    let titleLabel = NSTextField(labelWithString: title)
    titleLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
    titleLabel.lineBreakMode = .byTruncatingTail
    titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

    let identityView = NSStackView(views: [avatar, titleLabel])
    identityView.orientation = .horizontal
    identityView.alignment = .centerY
    identityView.spacing = 8
    identityView.edgeInsets = NSEdgeInsets(top: 0, left: 4, bottom: 0, right: 4)
    identityView.translatesAutoresizingMaskIntoConstraints = false

    super.init(frame: .zero)
    addSubview(identityView)
    NSLayoutConstraint.activate([
      identityView.leadingAnchor.constraint(equalTo: leadingAnchor),
      identityView.trailingAnchor.constraint(equalTo: trailingAnchor),
      identityView.centerYAnchor.constraint(equalTo: centerYAnchor),
      avatar.widthAnchor.constraint(equalToConstant: 24),
      avatar.heightAnchor.constraint(equalToConstant: 24),
      titleLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 260),
    ])

    let contentWidth = min(identityView.fittingSize.width, 300)
    setFrameSize(NSSize(width: contentWidth, height: 32))
    setContentHuggingPriority(.defaultHigh, for: .horizontal)
    setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
}

@MainActor
private final class GridScreenShareToolbarAvatarView: NSView {
  private let imageView = NSImageView()
  private let initialsLabel = NSTextField(labelWithString: "")
  private var imageTask: Task<Void, Never>?

  init(identity: GridScreenShareToolbarIdentity, size: CGFloat) {
    super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))

    wantsLayer = true
    layer?.backgroundColor = NSColor.controlAccentColor.cgColor
    layer?.cornerRadius = size / 2
    layer?.masksToBounds = true

    imageView.imageScaling = .scaleProportionallyUpOrDown
    imageView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(imageView)

    initialsLabel.stringValue = Self.initials(for: identity)
    initialsLabel.alignment = .center
    initialsLabel.font = .systemFont(ofSize: size * 0.42, weight: .semibold)
    initialsLabel.textColor = .white
    initialsLabel.translatesAutoresizingMaskIntoConstraints = false
    addSubview(initialsLabel)

    NSLayoutConstraint.activate([
      imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
      imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
      imageView.topAnchor.constraint(equalTo: topAnchor),
      imageView.bottomAnchor.constraint(equalTo: bottomAnchor),
      initialsLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
      initialsLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])

    loadImage(for: identity)
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  deinit {
    imageTask?.cancel()
  }

  private func loadImage(for identity: GridScreenShareToolbarIdentity) {
    if let localURL = identity.localAvatarURL,
       let image = NSImage(contentsOf: localURL) {
      show(image)
      return
    }
    guard let remoteURL = identity.remoteAvatarURL else { return }

    imageTask = Task { [weak self] in
      do {
        let (data, _) = try await URLSession.shared.data(from: remoteURL)
        guard !Task.isCancelled, let image = NSImage(data: data) else { return }
        self?.show(image)
      } catch {
        // Initials remain the stable fallback if the optional avatar cannot load.
      }
    }
  }

  private func show(_ image: NSImage) {
    imageView.image = image
    initialsLabel.isHidden = true
    layer?.backgroundColor = NSColor.clear.cgColor
  }

  private static func initials(for identity: GridScreenShareToolbarIdentity) -> String {
    let explicit = [identity.firstName, identity.lastName]
      .compactMap { $0?.first }
    if !explicit.isEmpty {
      return String(explicit.prefix(2)).uppercased()
    }
    let fallback = identity.displayName.split(whereSeparator: \.isWhitespace)
      .compactMap(\.first)
    return String(fallback.prefix(2)).uppercased()
  }
}
