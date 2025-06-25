import InlineKit
import UIKit

class FloatingMetadataView: UIView {
  private let metadataView: MessageTimeAndStatus
  private let materialBackgroundView = UIView()

  init(fullMessage: FullMessage) {
    metadataView = MessageTimeAndStatus(fullMessage)
    super.init(frame: .zero)

    setupViews()
    forceWhiteText()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func setupViews() {
    materialBackgroundView.backgroundColor = UIColor.black.withAlphaComponent(0.6)
    UIView.performWithoutAnimation {
      materialBackgroundView.layer.cornerRadius = 10
    }
    materialBackgroundView.clipsToBounds = true
    materialBackgroundView.translatesAutoresizingMaskIntoConstraints = false

    addSubview(materialBackgroundView)
    addSubview(metadataView)

    metadataView.translatesAutoresizingMaskIntoConstraints = false

    let contentVerticalPadding: CGFloat = 10
    let contentHorizontalPadding: CGFloat = 6

    NSLayoutConstraint.activate([
      materialBackgroundView.topAnchor.constraint(equalTo: topAnchor),
      materialBackgroundView.leadingAnchor.constraint(equalTo: leadingAnchor),
      materialBackgroundView.trailingAnchor.constraint(equalTo: trailingAnchor),
      materialBackgroundView.bottomAnchor.constraint(equalTo: bottomAnchor),

      metadataView.topAnchor.constraint(equalTo: topAnchor, constant: contentVerticalPadding),
      metadataView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: contentHorizontalPadding),
      metadataView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -contentHorizontalPadding),
      metadataView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -contentVerticalPadding),
    ])
  }

  private func forceWhiteText() {
    for subview in metadataView.subviews {
      if let label = subview as? UILabel {
        label.textColor = .white
      } else if let imageView = subview as? UIImageView {
        imageView.tintColor = .white
      }
    }
  }
}
