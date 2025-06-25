import UIKit

class ReplyIndicatorView: UIView {
  private let iconView = UIImageView()
  private let backgroundCircleView = UIView()

  override init(frame: CGRect) {
    super.init(frame: frame)
    setupView()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func setupView() {
    
    backgroundCircleView.translatesAutoresizingMaskIntoConstraints = false
    backgroundCircleView.backgroundColor = ThemeManager.shared.selected.accent.withAlphaComponent(0.2)
    backgroundCircleView.layer.cornerRadius = 14
    backgroundCircleView.alpha = 0
    
    addSubview(backgroundCircleView)
    
    
    iconView.image = UIImage(systemName: "arrowshape.turn.up.left.fill")
    iconView.tintColor =  ThemeManager.shared.selected.accent
    iconView.translatesAutoresizingMaskIntoConstraints = false
    iconView.alpha = 0
    
    addSubview(iconView)

    NSLayoutConstraint.activate([
       backgroundCircleView.centerXAnchor.constraint(equalTo: centerXAnchor),
       backgroundCircleView.centerYAnchor.constraint(equalTo: centerYAnchor),
       backgroundCircleView.widthAnchor.constraint(equalToConstant: 28),
       backgroundCircleView.heightAnchor.constraint(equalToConstant: 28),
       
       iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
       iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
       iconView.widthAnchor.constraint(equalToConstant: 18),
       iconView.heightAnchor.constraint(equalToConstant: 18),
     ])
  }

  func updateProgress(_ progress: CGFloat) {
     let scaleFactor = 0.8 + (progress * 0.4)
     let scaleTransform = CGAffineTransform(scaleX: scaleFactor, y: scaleFactor)

     UIView.animate(withDuration: 0.18, delay: 0, options: .curveEaseOut) {
       self.iconView.transform = scaleTransform
       self.iconView.alpha = progress * 1.2
       self.backgroundCircleView.transform = scaleTransform
       self.backgroundCircleView.alpha = progress * 1.2
     }
   }


  func reset() {
    iconView.transform = .identity
    iconView.alpha = 0
    backgroundCircleView.transform = .identity
    backgroundCircleView.alpha = 0

  }

  override func layoutSubviews() {
    super.layoutSubviews()
    layer.cornerRadius = bounds.height / 2
    
  }
}
