import InlineKit
import UIKit

class MessageEmbedView: UIView {
  // MARK: - UI Components
    
  let containerView: UIView = {
    let view = UIView()
    view.layer.cornerRadius = 8
    view.clipsToBounds = true
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }()
    
  let verticalBar: UIView = {
    let view = UIView()
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }()
    
  let nameLabel: UILabel = {
    let label = UILabel()
    label.font = .systemFont(ofSize: 13, weight: .medium)
    label.textAlignment = .left
    label.setContentHuggingPriority(.required, for: .vertical)
    label.setContentCompressionResistancePriority(.required, for: .vertical)
    label.translatesAutoresizingMaskIntoConstraints = false
    return label
  }()
    
  let messageLabel: UILabel = {
    let label = UILabel()
    label.font = .systemFont(ofSize: 15)
    label.numberOfLines = 1
    label.lineBreakMode = .byTruncatingTail
    label.textAlignment = .left
    label.setContentHuggingPriority(.required, for: .vertical)
    label.setContentCompressionResistancePriority(.required, for: .horizontal)
    label.translatesAutoresizingMaskIntoConstraints = false
    return label
  }()
    
  // MARK: - Properties

  var repliedToMessage: Message? {
    didSet { updateContent() }
  }
    
  // MARK: - Initialization

  init(repliedToMessage: Message?) {
    super.init(frame: .zero)
    self.repliedToMessage = repliedToMessage
    setupViews()
  }
    
  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
    
  // MARK: - Setup

  func setupViews() {
    addSubview(containerView)
    containerView.addSubview(verticalBar)
    containerView.addSubview(nameLabel)
    containerView.addSubview(messageLabel)
        
    NSLayoutConstraint.activate([
      // Container constraints
      containerView.topAnchor.constraint(equalTo: topAnchor),
      containerView.leadingAnchor.constraint(equalTo: leadingAnchor),
      containerView.trailingAnchor.constraint(equalTo: trailingAnchor),
      containerView.bottomAnchor.constraint(equalTo: bottomAnchor),
      containerView.heightAnchor.constraint(equalToConstant: 44),
            
      // Vertical bar constraints
      verticalBar.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 4),
      verticalBar.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 4),
      verticalBar.bottomAnchor.constraint(equalTo: containerView.bottomAnchor, constant: -4),
      verticalBar.widthAnchor.constraint(equalToConstant: 2),
            
      // Name label constraints
      nameLabel.leadingAnchor.constraint(equalTo: verticalBar.trailingAnchor, constant: 8),
      nameLabel.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -8),
      nameLabel.topAnchor.constraint(equalTo: verticalBar.topAnchor),
            
      // Message label constraints
      messageLabel.leadingAnchor.constraint(equalTo: verticalBar.trailingAnchor, constant: 8),
      messageLabel.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -8),
      messageLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 2),
      messageLabel.bottomAnchor.constraint(equalTo: verticalBar.bottomAnchor)
    ])
  }
    
  // MARK: - Content Update

  func updateContent() {
    guard let message = repliedToMessage else { return }
        
    let isOutgoing = message.out == true
    containerView.backgroundColor = isOutgoing ?
      .systemBlue.withAlphaComponent(0.1) :
      .systemGray6.withAlphaComponent(0.7)
    verticalBar.backgroundColor = isOutgoing ? .systemBlue : .systemGray3
        
    nameLabel.text = "User"
    messageLabel.text = message.text
        
    let textColor: UIColor = .label
    nameLabel.textColor = textColor.withAlphaComponent(0.8)
    messageLabel.textColor = textColor
  }
}
