import InlineKit
import UIKit

class EmbedMessageView: UIView {
  private enum Constants {
    static let cornerRadius: CGFloat = 8
    static let rectangleWidth: CGFloat = 4
    static let contentSpacing: CGFloat = 6
    static let verticalPadding: CGFloat = 2
    static let horizontalPadding: CGFloat = 6
  }
    
  static let height = 42.0
  private var outgoing: Bool = false
    
  private lazy var headerLabel: UILabel = {
    let label = UILabel()
    label.translatesAutoresizingMaskIntoConstraints = false
    label.font = .systemFont(ofSize: 14, weight: .bold)
    label.numberOfLines = 1
    
    return label
  }()

  private lazy var messageLabel: UILabel = {
    let label = UILabel()
    label.translatesAutoresizingMaskIntoConstraints = false
    label.font = .systemFont(ofSize: 14)
    label.numberOfLines = 1
    return label
  }()

  private lazy var rectangleView: UIView = {
    let view = UIView()
    view.translatesAutoresizingMaskIntoConstraints = false
    view.layer.mask = CAShapeLayer()
    return view
  }()
    
  override init(frame: CGRect) {
    super.init(frame: frame)
    setupViews()
    setupLayer()
  }
    
  required init?(coder: NSCoder) {
    super.init(coder: coder)
    setupViews()
    setupLayer()
  }
    
  override func layoutSubviews() {
    super.layoutSubviews()
    updateRectangleMask()
  }
    
  func configure(message: Message, senderName: String, outgoing: Bool) {
    self.outgoing = outgoing
    headerLabel.text = senderName
    messageLabel.text = message.text
    updateColors()
  }
}

private extension EmbedMessageView {
  func setupViews() {
    addSubview(rectangleView)
    addSubview(headerLabel)
    addSubview(messageLabel)
        
    NSLayoutConstraint.activate([
      rectangleView.leadingAnchor.constraint(equalTo: leadingAnchor),
      rectangleView.widthAnchor.constraint(equalToConstant: Constants.rectangleWidth),
      rectangleView.topAnchor.constraint(equalTo: topAnchor),
      rectangleView.bottomAnchor.constraint(equalTo: bottomAnchor),
            
      headerLabel.leadingAnchor.constraint(equalTo: rectangleView.trailingAnchor,
                                           constant: Constants.contentSpacing),
      headerLabel.trailingAnchor.constraint(equalTo: trailingAnchor,
                                            constant: -Constants.horizontalPadding),
      headerLabel.topAnchor.constraint(equalTo: topAnchor,
                                       constant: Constants.verticalPadding),
      headerLabel.bottomAnchor.constraint(equalTo: messageLabel.topAnchor),
      messageLabel.leadingAnchor.constraint(equalTo: rectangleView.trailingAnchor,
                                            constant: Constants.contentSpacing),
      messageLabel.trailingAnchor.constraint(equalTo: trailingAnchor,
                                             constant: -Constants.horizontalPadding),
      messageLabel.bottomAnchor.constraint(equalTo: bottomAnchor,
                                           constant: -Constants.verticalPadding)
    ])
  }
    
  func setupLayer() {
    layer.cornerRadius = Constants.cornerRadius
    layer.masksToBounds = true
  }
    
  func updateColors() {
    let textColor: UIColor = outgoing ? .white : .darkGray
    let rectangleColor = outgoing ? UIColor.white : .systemGray
    let bgAlpha: CGFloat = outgoing ? 0.13 : 0.1
    backgroundColor = outgoing ? .white.withAlphaComponent(bgAlpha) : .systemGray.withAlphaComponent(bgAlpha)
        
    headerLabel.textColor = textColor
    messageLabel.textColor = textColor
    rectangleView.backgroundColor = rectangleColor
  }
}

private extension EmbedMessageView {
  func updateRectangleMask() {
    let path = UIBezierPath(
      roundedRect: rectangleView.bounds,
      byRoundingCorners: [.topLeft, .bottomLeft],
      cornerRadii: CGSize(width: Constants.cornerRadius, height: Constants.cornerRadius)
    )
        
    if let mask = rectangleView.layer.mask as? CAShapeLayer {
      mask.path = path.cgPath
    }
  }
}
