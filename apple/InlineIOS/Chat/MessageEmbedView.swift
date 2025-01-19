import InlineKit
import UIKit

extension String {
  var isRTL: Bool {
    guard let firstChar = first else { return false }
    let earlyRTL =
      firstChar.unicodeScalars.first?.properties.generalCategory == .otherLetter
        && firstChar.unicodeScalars.first != nil
        && firstChar.unicodeScalars.first!.value >= 0x0590
        && firstChar.unicodeScalars.first!.value <= 0x08FF

    if earlyRTL { return true }

    let language = CFStringTokenizerCopyBestStringLanguage(
      self as CFString,
      CFRange(location: 0, length: count)
    )
    if let language = language {
      return NSLocale.characterDirection(forLanguage: language as String) == .rightToLeft
    }
    return false
  }
}

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
    label.translatesAutoresizingMaskIntoConstraints = false
    return label
  }()
    
  let messageLabel: UILabel = {
    let label = UILabel()
    label.font = .systemFont(ofSize: 15)
    label.numberOfLines = 1
    label.lineBreakMode = .byTruncatingTail
    label.translatesAutoresizingMaskIntoConstraints = false
    return label
  }()
    
  let stackView: UIStackView = {
    let stack = UIStackView()
    stack.axis = .vertical
    stack.spacing = 2
    stack.alignment = .leading
    stack.translatesAutoresizingMaskIntoConstraints = false
    return stack
  }()
    
  // MARK: - Properties
    
  var repliedToMessage: Message? {
    didSet {
      updateContent()
    }
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
    containerView.addSubview(stackView)
        
    stackView.addArrangedSubview(nameLabel)
    stackView.addArrangedSubview(messageLabel)
        
    NSLayoutConstraint.activate([
      // Container constraints
      containerView.topAnchor.constraint(equalTo: topAnchor),
      containerView.leadingAnchor.constraint(equalTo: leadingAnchor),
      containerView.trailingAnchor.constraint(equalTo: trailingAnchor),
      containerView.bottomAnchor.constraint(equalTo: bottomAnchor),
            
      // Vertical bar constraints
      verticalBar.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 4),
      verticalBar.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 4),
      verticalBar.bottomAnchor.constraint(equalTo: containerView.bottomAnchor, constant: -4),
      verticalBar.widthAnchor.constraint(equalToConstant: 2),
            
      // Stack view constraints
      stackView.leadingAnchor.constraint(equalTo: verticalBar.trailingAnchor, constant: 8),
      stackView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -8),
      stackView.centerYAnchor.constraint(equalTo: containerView.centerYAnchor),
            
      // Fixed height for better performance
      containerView.heightAnchor.constraint(equalToConstant: 44)
    ])
  }
    
  func updateContent() {
    guard let message = repliedToMessage else { return }
        
    let isOutgoing = message.out == true
    let backgroundColor: UIColor = isOutgoing ?
      .systemBlue.withAlphaComponent(0.1) :
      .systemGray6.withAlphaComponent(0.7)
    let barColor: UIColor = isOutgoing ? .systemBlue : .systemGray3
    let textColor: UIColor = .label
        
    containerView.backgroundColor = backgroundColor
    verticalBar.backgroundColor = barColor
    nameLabel.textColor = textColor.withAlphaComponent(0.8)
    messageLabel.textColor = textColor
        
    nameLabel.text = "User"
    messageLabel.text = message.text
        
    // Handle RTL if needed
    if message.text?.isRTL == true {
      messageLabel.textAlignment = .right
      stackView.alignment = .trailing
    } else {
      messageLabel.textAlignment = .left
      stackView.alignment = .leading
    }
  }
}
