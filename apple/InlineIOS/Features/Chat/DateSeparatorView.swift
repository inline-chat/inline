import UIKit

final class DateSeparatorView: UICollectionReusableView {
  static let reuseIdentifier = "DateSeparatorView"
  static let height: CGFloat = 44
  
  // Performance optimization: Cache the current date string to avoid unnecessary updates
  private var currentDateString: String = ""
  
  private let label: UILabel = {
    let label = UILabel()
    label.font = UIFont.systemFont(ofSize: 11, weight: .medium)
    label.textColor = UIColor.secondaryLabel
    label.textAlignment = .center
    label.translatesAutoresizingMaskIntoConstraints = false
    return label
  }()
  
  private let backgroundView: UIView = {
    let view = UIView()
    view.backgroundColor = UIColor.tertiarySystemBackground
    view.layer.cornerRadius = 8
    view.layer.cornerCurve = .continuous
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }()
  
  override init(frame: CGRect) {
    super.init(frame: frame)
    setupViews()
  }
  
  required init?(coder: NSCoder) {
    super.init(coder: coder)
    setupViews()
  }
  
  private func setupViews() {
    addSubview(backgroundView)
    backgroundView.addSubview(label)
    
    // Counter the collection view's inversion to appear right-side up
    backgroundView.transform = CGAffineTransform(scaleX: 1, y: -1)
    
    NSLayoutConstraint.activate([
      backgroundView.centerXAnchor.constraint(equalTo: centerXAnchor),
      backgroundView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
      backgroundView.heightAnchor.constraint(equalToConstant: 20),
      backgroundView.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 16),
      backgroundView.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
      
      label.leadingAnchor.constraint(equalTo: backgroundView.leadingAnchor, constant: 8),
      label.trailingAnchor.constraint(equalTo: backgroundView.trailingAnchor, constant: -8),
      label.centerYAnchor.constraint(equalTo: backgroundView.centerYAnchor)
    ])
  }
  
  func configure(with dateString: String) {
    // Performance optimization: Only update if the date string actually changed
    guard currentDateString != dateString else { return }
    
    let shouldAnimate = !currentDateString.isEmpty && !dateString.isEmpty
    currentDateString = dateString
    label.text = dateString
    
    if shouldAnimate {
      // Fade in animation
      alpha = 0
      UIView.animate(withDuration: 0.2, delay: 0, options: [.allowUserInteraction]) {
        self.alpha = 1
      }
    } else {
      alpha = 1
    }
  }
  
  override func prepareForReuse() {
    super.prepareForReuse()
    currentDateString = ""
    label.text = ""
    alpha = 1
  }
}