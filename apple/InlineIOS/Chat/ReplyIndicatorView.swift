import UIKit

class ReplyIndicatorView: UIView {
  private let iconView = UIImageView()

  override init(frame: CGRect) {
    super.init(frame: frame)
    setupView()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func setupView() {
    iconView.image = UIImage(systemName: "arrowshape.turn.up.left.fill")
    iconView.tintColor = .systemGray4
    iconView.translatesAutoresizingMaskIntoConstraints = false
    iconView.alpha = 0
    addSubview(iconView)

    NSLayoutConstraint.activate([
      iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
      iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
      iconView.widthAnchor.constraint(equalToConstant: 24),
      iconView.heightAnchor.constraint(equalToConstant: 24),
    ])
  }

  func updateProgress(_ progress: CGFloat) {
    let scaleFactor = 0.8 + (progress * 0.4)
    let scaleTransform = CGAffineTransform(scaleX: scaleFactor, y: scaleFactor)

    UIView.animate(withDuration: 0.2, delay: 0, options: .curveEaseOut) {
      self.iconView.transform = scaleTransform
      self.iconView.alpha = progress * 1.2
    }
  }

  func reset() {
    iconView.transform = .identity
    iconView.alpha = 0
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    layer.cornerRadius = bounds.height / 2
  }
}
