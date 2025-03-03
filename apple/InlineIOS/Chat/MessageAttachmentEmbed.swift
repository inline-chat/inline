import InlineKit
import UIKit

class MessageAttachmentEmbed: UIView {
  private enum Constants {
    static let cornerRadius: CGFloat = 12
    static let rectangleWidth: CGFloat = 4
    static let contentSpacing: CGFloat = 6
    static let verticalPadding: CGFloat = 8
    static let horizontalPadding: CGFloat = 6
  }
    
  static let height = 28.0
  private var outgoing: Bool = false
    
  private lazy var circleImageView: UIImageView = {
    let imageView = UIImageView()
    imageView.translatesAutoresizingMaskIntoConstraints = false
    let config = UIImage.SymbolConfiguration(pointSize: 14, weight: .regular)
    imageView.image = UIImage(systemName: "circle", withConfiguration: config)
    imageView.contentMode = .scaleAspectFit
    return imageView
  }()
    
  private lazy var messageLabel: UILabel = {
    let label = UILabel()
    label.translatesAutoresizingMaskIntoConstraints = false
    label.font = .systemFont(ofSize: 17)
    label.numberOfLines = 1
    return label
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
    
  func configure(userName: String, outgoing: Bool) {
    self.outgoing = outgoing
    messageLabel.text = "\(userName) will do"
    updateColors()
  }
}

private extension MessageAttachmentEmbed {
  func setupViews() {
    addSubview(circleImageView)
    addSubview(messageLabel)
        
    NSLayoutConstraint.activate([
      circleImageView.leadingAnchor.constraint(
        equalTo: leadingAnchor,
        constant: Constants.horizontalPadding
      ),
      circleImageView.centerYAnchor.constraint(equalTo: centerYAnchor),
      circleImageView.widthAnchor.constraint(equalToConstant: 16),
      circleImageView.heightAnchor.constraint(equalToConstant: 16),
            
      messageLabel.leadingAnchor.constraint(
        equalTo: circleImageView.trailingAnchor,
        constant: Constants.contentSpacing
      ),
      messageLabel.trailingAnchor.constraint(
        equalTo: trailingAnchor,
        constant: -Constants.horizontalPadding
      ),
      messageLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            
      heightAnchor.constraint(equalToConstant: MessageAttachmentEmbed.height),
    ])
  }
    
  func setupLayer() {
    layer.cornerRadius = Constants.cornerRadius
    layer.masksToBounds = true
  }
    
  func updateColors() {
    let textColor: UIColor = outgoing ? .white : .label
    let bgAlpha: CGFloat = outgoing ? 0.13 : 0.08
    backgroundColor = outgoing ? .white.withAlphaComponent(bgAlpha) : .systemGray.withAlphaComponent(bgAlpha)
        
    messageLabel.textColor = textColor
    circleImageView.tintColor = textColor
  }
}
