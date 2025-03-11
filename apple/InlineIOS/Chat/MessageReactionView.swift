import InlineKit
import UIKit
class MessageReactionView: UIView {
  // MARK: - Properties
    
  private let emoji: String
  private let count: Int
  private let isSelected: Bool
  private let outgoing: Bool
    
  var onTap: ((String) -> Void)?
    
  // MARK: - UI Components
    
  private lazy var containerView: UIView = {
    let view = UIView()
    view.layer.cornerRadius = 12
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }()
    
  private lazy var stackView: UIStackView = {
    let stack = UIStackView()
    stack.axis = .horizontal
    stack.spacing = 4
    stack.alignment = .center
    stack.translatesAutoresizingMaskIntoConstraints = false
    return stack
  }()
    
  private lazy var emojiLabel: UILabel = {
    let label = UILabel()
    label.font = UIFont.systemFont(ofSize: 16)
    label.text = emoji
    return label
  }()
    
  private lazy var countLabel: UILabel = {
    let label = UILabel()
    label.font = UIFont.systemFont(ofSize: 12, weight: .medium)
    label.text = "\(count)"
    return label
  }()
    
  // MARK: - Initialization
    
  init(emoji: String, count: Int, isSelected: Bool, outgoing: Bool) {
    self.emoji = emoji
    self.count = count
    self.isSelected = isSelected
    self.outgoing = outgoing
        
    super.init(frame: .zero)
    setupView()
  }
    
  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
    
  // MARK: - Setup
    
  private func setupView() {
    // Configure container appearance
    containerView.backgroundColor = isSelected ?
      (outgoing ? UIColor.white.withAlphaComponent(0.3) : ColorManager.shared.selectedColor.withAlphaComponent(0.3)) :
      (outgoing ? UIColor.white.withAlphaComponent(0.15) : UIColor.systemGray6)
        
    // Configure text colors
    countLabel.textColor = outgoing ? .white.withAlphaComponent(0.9) : .darkGray
        
    // Add subviews
    addSubview(containerView)
    containerView.addSubview(stackView)
        
    stackView.addArrangedSubview(emojiLabel)
    stackView.addArrangedSubview(countLabel)
        
    // Setup constraints
    NSLayoutConstraint.activate([
      containerView.topAnchor.constraint(equalTo: topAnchor),
      containerView.leadingAnchor.constraint(equalTo: leadingAnchor),
      containerView.trailingAnchor.constraint(equalTo: trailingAnchor),
      containerView.bottomAnchor.constraint(equalTo: bottomAnchor),
            
      stackView.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 4),
      stackView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 8),
      stackView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -8),
      stackView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor, constant: -4)
    ])
        
    // Add tap gesture
    let tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleTap))
    containerView.addGestureRecognizer(tapGesture)
    containerView.isUserInteractionEnabled = true
  }
    
  // MARK: - Actions
    
  @objc private func handleTap() {
    onTap?(emoji)
  }
    
  // MARK: - Layout
    
  override var intrinsicContentSize: CGSize {
    let stackSize = stackView.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
    return CGSize(width: stackSize.width + 16, height: stackSize.height + 8)
  }
    
  override func sizeThatFits(_ size: CGSize) -> CGSize {
    return intrinsicContentSize
  }
}
