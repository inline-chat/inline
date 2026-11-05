import InlineKit
import UIKit

/// A short upload bar under an outgoing photo's bubble, like Messages.
final class PhotoUploadProgressView: UIView {
  static let size = CGSize(width: 60, height: 4)
  static let topSpacing: CGFloat = 4
  private static let minimumFraction: Double = 0.04

  private let bar = UIProgressView(progressViewStyle: .default)
  private let binding = PhotoUploadProgressBinding()
  private var photoLocalId: Int64?

  override init(frame: CGRect) {
    super.init(frame: frame)
    isUserInteractionEnabled = false
    bar.translatesAutoresizingMaskIntoConstraints = false
    bar.progressTintColor = ThemeManager.shared.selected.accent
    bar.trackTintColor = .systemGray5
    addSubview(bar)
    NSLayoutConstraint.activate([
      bar.leadingAnchor.constraint(equalTo: leadingAnchor),
      bar.trailingAnchor.constraint(equalTo: trailingAnchor),
      bar.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func configure(photoLocalId: Int64) {
    guard self.photoLocalId != photoLocalId else { return }
    self.photoLocalId = photoLocalId
    bar.progress = Float(Self.minimumFraction)
    binding.bind(photoLocalId: photoLocalId) { [weak self] progress in
      self?.bar.setProgress(Float(max(Self.minimumFraction, progress.fractionCompleted)), animated: true)
    }
  }

  /// Fills the bar when `filling`, fades it out and removes it.
  func dismiss(filling: Bool, animated: Bool) {
    binding.clear()
    guard animated else {
      removeFromSuperview()
      return
    }
    if filling {
      bar.setProgress(1, animated: true)
    }
    UIView.animate(withDuration: 0.2, delay: filling ? 0.25 : 0, options: [.beginFromCurrentState]) {
      self.alpha = 0
    } completion: { _ in
      self.removeFromSuperview()
    }
  }
}
