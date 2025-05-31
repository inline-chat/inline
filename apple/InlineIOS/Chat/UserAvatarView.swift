import InlineKit
import InlineUI
import Logger
import Nuke
import NukeUI
import UIKit

final class UserAvatarView: UIView {
  // MARK: - Properties

  private let imageView: LazyImageView = {
    let view = LazyImageView()
    view.contentMode = .scaleAspectFit
    view.clipsToBounds = true
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }()

  private let initialsLabel: UILabel = {
    let label = UILabel()
    label.textAlignment = .center
    label.textColor = .white
    label.font = .systemFont(ofSize: 16, weight: .medium)
    label.translatesAutoresizingMaskIntoConstraints = false
    return label
  }()

  private let gradientLayer: CAGradientLayer = {
    let layer = CAGradientLayer()
    layer.startPoint = CGPoint(x: 0.5, y: 0)
    layer.endPoint = CGPoint(x: 0.5, y: 1)
    layer.type = .axial
    return layer
  }()

  private var size: CGFloat = 32
  private var nameForInitials: String = ""

  public static func getNameForInitials(user: User) -> String {
    let firstName = user.firstName ?? user.email?.components(separatedBy: "@").first ?? "User"
    let lastName = user.lastName
    let name = "\(firstName)\(lastName != nil ? " \(lastName ?? "")" : "")"
    return name
  }

  // MARK: - Initialization

  override init(frame: CGRect) {
    super.init(frame: frame)
    setupViews()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  // MARK: - Setup

  private func setupViews() {
    layer.masksToBounds = true
    layer.addSublayer(gradientLayer)

    addSubview(imageView)
    addSubview(initialsLabel)

    NSLayoutConstraint.activate([
      imageView.topAnchor.constraint(equalTo: topAnchor),
      imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
      imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
      imageView.bottomAnchor.constraint(equalTo: bottomAnchor),

      initialsLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
      initialsLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    layer.cornerRadius = bounds.width / 2
    gradientLayer.frame = bounds
  }

  // MARK: - Configuration

  func configure(with userInfo: UserInfo, size: CGFloat = 32) {
    self.size = size

    // Only set size constraints if they haven't been set externally
    if constraints.isEmpty {
      NSLayoutConstraint.activate([
        widthAnchor.constraint(equalToConstant: size),
        heightAnchor.constraint(equalToConstant: size),
      ])
    }

    // Get name for initials
    let user = userInfo.user
    nameForInitials = AvatarColorUtility.formatNameForHashing(
      firstName: user.firstName,
      lastName: user.lastName,
      email: user.email
    )

    // Update initials
    initialsLabel.text = nameForInitials.first.map(String.init)?.uppercased() ?? ""

    // Update gradient colors
    let baseColor = AvatarColorUtility.uiColorFor(name: nameForInitials)
    let isDarkMode = traitCollection.userInterfaceStyle == .dark
    let adjustedColor = isDarkMode ? baseColor.adjustLuminosity(by: -0.1) : baseColor

    gradientLayer.colors = [
      adjustedColor.adjustLuminosity(by: 0.2).cgColor,
      adjustedColor.cgColor,
    ]

    // Load image if available
    if var photo = userInfo.profilePhoto?.first {
      loadProfileImage(photo: photo)
    } else {
      showInitials()
    }
  }

  private func loadProfileImage(photo: InlineKit.File) {
    // Show initials initially while loading
    initialsLabel.isHidden = false

    if let localUrl = photo.getLocalURL() {
      imageView.request = ImageRequest(
        url: localUrl,
        processors: [.resize(width: 96)],
        priority: .high
      )

      // Set up success/failure handlers
      imageView.onSuccess = { [weak self] _ in
        DispatchQueue.main.async {
          self?.initialsLabel.isHidden = true
        }
      }

      imageView.onFailure = { [weak self] _ in
        DispatchQueue.main.async {
          self?.showInitials()
        }
      }

    } else if let remoteUrl = photo.getRemoteURL() {
      imageView.request = ImageRequest(
        url: remoteUrl,
        processors: [.resize(width: 96)],
        priority: .high
      )

      // Set up success/failure handlers
      imageView.onSuccess = { [weak self] _ in
        DispatchQueue.main.async {
          self?.initialsLabel.isHidden = true
        }
      }

      imageView.onFailure = { [weak self] _ in
        DispatchQueue.main.async {
          self?.showInitials()
        }
      }

      // Save image locally when loaded
      Task.detached(priority: .userInitiated) { [weak self] in
        guard self != nil else { return }
        do {
          let image = try await ImagePipeline.shared.image(for: remoteUrl)
          let directory = FileHelpers.getDocumentsDirectory()
          let fileName = photo.fileName ?? ""
          if let (pathString, _) = try? image.save(
            to: directory,
            withName: fileName,
            format: photo.imageFormat
          ) {
            var updatedPhoto = photo
            updatedPhoto.localPath = pathString
            try? await AppDatabase.shared.dbWriter.write { db in
              try updatedPhoto.save(db)
            }
          }
        } catch {
          Log.shared.error("Failed to load and cache profile image", error: error)
        }
      }
    } else {
      showInitials()
    }
  }

  private func showInitials() {
    initialsLabel.isHidden = false
    imageView.request = nil
  }

  // MARK: - Private Helpers

  private func colorForName(_ name: String) -> UIColor {
    let colors: [UIColor] = [
      UIColor(.pink).adjustLuminosity(by: -0.1),
      .orange,
      .purple,
      .yellow.adjustLuminosity(by: -0.1),
      UIColor(.teal),
      .blue,
      UIColor(.teal),
      .green,
      UIColor(.primary),
      .red,
      UIColor(.indigo),
      UIColor(.mint),
      UIColor(.cyan),
    ]

    let hash = name.utf8.reduce(0) { $0 + Int($1) }
    return colors[abs(hash) % colors.count]
  }
}

// MARK: - UIColor Extensions

public extension UIColor {
  func adjustLuminosity(by percentage: CGFloat) -> UIColor {
    var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
    guard getRed(&r, green: &g, blue: &b, alpha: &a) else { return self }
    return UIColor(
      red: min(r + (1 - r) * percentage, 1.0),
      green: min(g + (1 - g) * percentage, 1.0),
      blue: min(b + (1 - b) * percentage, 1.0),
      alpha: a
    )
  }
}
