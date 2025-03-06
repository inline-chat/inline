import InlineKit
import UIKit

private let dateFormatter: DateFormatter = {
  let formatter = DateFormatter()
  formatter.dateFormat = "HH:mm"
  return formatter
}()

class FloutingMetadata: UIView {
  private let symbolSize: CGFloat = 11
  private let blurEffectView: UIVisualEffectView
    
  private let dateLabel: UILabel = {
    let label = UILabel()
    label.font = .systemFont(ofSize: 11)
    label.translatesAutoresizingMaskIntoConstraints = false
    return label
  }()
    
  private let statusImageView: UIImageView = {
    let imageView = UIImageView()
    imageView.contentMode = .scaleAspectFit
    imageView.translatesAutoresizingMaskIntoConstraints = false
    imageView.setContentHuggingPriority(.required, for: .horizontal)
    imageView.setContentCompressionResistancePriority(.required, for: .horizontal)
    return imageView
  }()
    
  let fullMessage: FullMessage
    
  var message: Message {
    fullMessage.message
  }
    
  var outgoing: Bool {
    message.out ?? false
  }
    
  init(_ message: FullMessage) {
    fullMessage = message
        
    // Create blur effect view with thin material
    let blurEffect = UIBlurEffect(style: .systemThinMaterial)
    blurEffectView = UIVisualEffectView(effect: blurEffect)
    blurEffectView.translatesAutoresizingMaskIntoConstraints = false
        
    super.init(frame: .zero)
    setupViews()
  }
    
  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
    
  private func setupViews() {
    // Add blur effect as background
    addSubview(blurEffectView)
        
    // Add content to the vibrancy effect view to make it pop against the blur
    let vibrancyEffect = UIVibrancyEffect(blurEffect: blurEffectView.effect as! UIBlurEffect)
    let vibrancyView = UIVisualEffectView(effect: vibrancyEffect)
    vibrancyView.translatesAutoresizingMaskIntoConstraints = false
        
    blurEffectView.contentView.addSubview(dateLabel)
    blurEffectView.contentView.addSubview(statusImageView)
        
    // Make the view rounded
    layer.cornerRadius = 8
    layer.masksToBounds = true
        
    // Add padding around the content
    layoutMargins = UIEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        
    setupConstraints()
    setupAppearance()
  }
    
  func setupConstraints() {
    // Make blur effect fill the entire view
    NSLayoutConstraint.activate([
      blurEffectView.topAnchor.constraint(equalTo: topAnchor),
      blurEffectView.leadingAnchor.constraint(equalTo: leadingAnchor),
      blurEffectView.trailingAnchor.constraint(equalTo: trailingAnchor),
      blurEffectView.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
        
    if outgoing {
      NSLayoutConstraint.activate([
        dateLabel.centerYAnchor.constraint(equalTo: blurEffectView.contentView.centerYAnchor),
        dateLabel.leadingAnchor.constraint(equalTo: layoutMarginsGuide.leadingAnchor),
        dateLabel.trailingAnchor.constraint(equalTo: statusImageView.leadingAnchor, constant: -4),
                
        statusImageView.centerYAnchor.constraint(equalTo: blurEffectView.contentView.centerYAnchor),
        statusImageView.trailingAnchor.constraint(equalTo: layoutMarginsGuide.trailingAnchor),
        statusImageView.widthAnchor.constraint(equalToConstant: symbolSize),
        statusImageView.heightAnchor.constraint(equalToConstant: symbolSize),
      ])
    } else {
      NSLayoutConstraint.activate([
        dateLabel.centerYAnchor.constraint(equalTo: blurEffectView.contentView.centerYAnchor),
        dateLabel.leadingAnchor.constraint(equalTo: layoutMarginsGuide.leadingAnchor),
        dateLabel.trailingAnchor.constraint(equalTo: layoutMarginsGuide.trailingAnchor),
      ])
    }
  }
    
  func setupAppearance() {
    dateLabel.text = dateFormatter.string(from: message.date)
        
    // Use system background color for text
    dateLabel.textColor = .systemBackground
        
    let imageName: String
    let symbolConfig = UIImage.SymbolConfiguration(pointSize: symbolSize)
      .applying(UIImage.SymbolConfiguration(weight: .medium))
        
    switch message.status {
    case .sent:
      imageName = "checkmark"
      statusImageView.preferredSymbolConfiguration = symbolConfig
    case .sending:
      imageName = "clock"
      statusImageView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: symbolSize - 1)
        .applying(UIImage.SymbolConfiguration(weight: .medium))
    case .failed:
      imageName = "exclamationmark"
      statusImageView.preferredSymbolConfiguration = symbolConfig
    case .none:
      imageName = ""
    }
        
    if let newImage = UIImage(systemName: imageName) {
      statusImageView.setSymbolImage(newImage, contentTransition: .replace)
    }
        
    // Use system background color for icon
    statusImageView.tintColor = .systemBackground
  }
}
