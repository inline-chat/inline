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
    UIView.performWithoutAnimation {
      layer.cornerRadius = bounds.width / 2
      gradientLayer.frame = bounds
    }
  }

  // MARK: - Configuration

  func configure(with userInfo: UserInfo, size: CGFloat = 32) {
    self.size = size
    let user = userInfo.user
    
    configureSize()
    configureInitials(for: user)
    configureColors()
    loadImage(for: user, userInfo: userInfo)
  }
  
  // MARK: - Private Configuration Methods
  
  private func configureSize() {
    guard constraints.isEmpty else { return }
    
    NSLayoutConstraint.activate([
      widthAnchor.constraint(equalToConstant: size),
      heightAnchor.constraint(equalToConstant: size),
    ])
  }
  
  private func configureInitials(for user: User) {
    nameForInitials = AvatarColorUtility.formatNameForHashing(
      firstName: user.firstName,
      lastName: user.lastName,
      email: user.email
    )
    
    initialsLabel.text = nameForInitials.first?.uppercased() ?? ""
  }
  
  private func configureColors() {
    let baseColor = AvatarColorUtility.uiColorFor(name: nameForInitials)
    let isDarkMode = traitCollection.userInterfaceStyle == .dark
    let adjustedColor = isDarkMode ? baseColor.adjustLuminosity(by: -0.1) : baseColor

    gradientLayer.colors = [
      adjustedColor.adjustLuminosity(by: 0.2).cgColor,
      adjustedColor.cgColor,
    ]
  }
  
  private func loadImage(for user: User, userInfo: UserInfo) {
    let localUrl = user.getLocalURL()
    let remoteUrl = user.getRemoteURL()

    if localUrl != nil || remoteUrl != nil {
      loadProfileImage(localUrl: localUrl, remoteUrl: remoteUrl, userInfo: userInfo)
    } else {
      showInitials()
    }
  }

  // MARK: - Image Loading
  
  private func loadProfileImage(localUrl: URL?, remoteUrl: URL?, userInfo: UserInfo) {
    guard let imageUrl = localUrl ?? remoteUrl else {
      showInitials()
      return
    }

    hideInitials()
    configureImageRequest(for: imageUrl)
    setupImageHandlers()
    cacheImageIfNeeded(localUrl: localUrl, remoteUrl: remoteUrl, userId: userInfo.user.id)
  }
  
  private func configureImageRequest(for url: URL) {
    imageView.request = ImageRequest(
      url: url,
      processors: [.resize(width: 96)],
      priority: .high
    )
  }
  
  private func setupImageHandlers() {
    imageView.onSuccess = { [weak self] _ in
      DispatchQueue.main.async {
        self?.hideInitials()
      }
    }

    imageView.onFailure = { [weak self] _ in
      DispatchQueue.main.async {
        self?.showInitials()
      }
    }
  }
  
  private func cacheImageIfNeeded(localUrl: URL?, remoteUrl: URL?, userId: Int64) {
    guard localUrl == nil, let remoteUrl = remoteUrl else { return }
    
    Task.detached(priority: .userInitiated) { [weak self] in
      guard self != nil else { return }
      do {
        let image = try await ImagePipeline.shared.image(for: remoteUrl)
        try await User.cacheImage(userId: userId, image: image)
      } catch {
        Log.shared.error("Failed to cache profile image", error: error)
      }
    }
  }
  
  private func hideInitials() {
    UIView.performWithoutAnimation {
      initialsLabel.isHidden = true
    }
  }

  private func showInitials() {
    UIView.performWithoutAnimation {
      initialsLabel.isHidden = false
      imageView.request = nil
    }
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
