import InlineKit
import UIKit

class LiquidGlassComposeView: ComposeContainer {
  // MARK: - Custom Properties

  private var externalButtonsContainer: UIView!
  private var textViewContainer: UIView!

  // MARK: - Initialization

  override init(configuration: Configuration = .default) {
    super.init(configuration: configuration)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  // MARK: - Setup Methods (Override these)

  override public func setupViews() {
    backgroundColor = .clear

    if #available(iOS 26.0, *) {
      textViewContainer = UIView()

      let glassEffect = UIGlassEffect()
      let glassView = UIVisualEffectView()
      UIView.animate {
        glassView.effect = glassEffect
      }
      glassView.translatesAutoresizingMaskIntoConstraints = false

      textViewContainer.addSubview(glassView)
      textViewContainer.translatesAutoresizingMaskIntoConstraints = false
      addSubview(textViewContainer)

      NSLayoutConstraint.activate([
        glassView.topAnchor.constraint(equalTo: textViewContainer.topAnchor),
        glassView.leadingAnchor.constraint(equalTo: textViewContainer.leadingAnchor),
        glassView.trailingAnchor.constraint(equalTo: textViewContainer.trailingAnchor),
        glassView.bottomAnchor.constraint(equalTo: textViewContainer.bottomAnchor),
      ])

      textViewContainer.addSubview(textView)

    } else {
      // Fallback for older iOS versions
      textViewContainer = UIView()
      textViewContainer.backgroundColor = .red
      textViewContainer.translatesAutoresizingMaskIntoConstraints = false
      textViewContainer.layer.cornerRadius = 20
      addSubview(textViewContainer)

      textViewContainer.addSubview(textView)
    }

    externalButtonsContainer = UIView()
    externalButtonsContainer.backgroundColor = .clear
    externalButtonsContainer.translatesAutoresizingMaskIntoConstraints = false
    addSubview(externalButtonsContainer)

    externalButtonsContainer.addSubview(sendButton)
    externalButtonsContainer.addSubview(attachmentButton)

    heightConstraint = heightAnchor.constraint(equalToConstant: configuration.minHeight)
    heightConstraint.isActive = true

    setupLayout()
    setupInitialState()

    // Apply custom UI styling
    customizeSendButton()
    customizePlusButton()

    if #available(iOS 26.0, *) {
      customizeGlassTextViewContainer()
    } else {
      customizeTextViewContainer()
    }
  }

  override func setupLayout() {
    NSLayoutConstraint.activate([
      // Text view container layout - centered with padding for external buttons
      textViewContainer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 50), // Space for plus button
      textViewContainer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -50), // Space for send button
      textViewContainer.topAnchor.constraint(equalTo: topAnchor, constant: 8),
      textViewContainer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),

      // Text view inside container
      textView.leadingAnchor.constraint(equalTo: textViewContainer.leadingAnchor, constant: 12),
      textView.trailingAnchor.constraint(equalTo: textViewContainer.trailingAnchor, constant: -12),
      textView.topAnchor.constraint(equalTo: textViewContainer.topAnchor, constant: 8),
      textView.bottomAnchor.constraint(equalTo: textViewContainer.bottomAnchor, constant: -8),

      // External buttons container
      externalButtonsContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
      externalButtonsContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
      externalButtonsContainer.topAnchor.constraint(equalTo: topAnchor),
      externalButtonsContainer.bottomAnchor.constraint(equalTo: bottomAnchor),

      // Plus button - positioned outside left of text container
      attachmentButton.leadingAnchor.constraint(equalTo: externalButtonsContainer.leadingAnchor, constant: 8),
      attachmentButton.centerYAnchor.constraint(equalTo: textViewContainer.centerYAnchor),
      attachmentButton.widthAnchor.constraint(equalToConstant: configuration.buttonSize.width),
      attachmentButton.heightAnchor.constraint(equalToConstant: configuration.buttonSize.height),

      // Send button - positioned outside right of text container
      sendButton.trailingAnchor.constraint(equalTo: externalButtonsContainer.trailingAnchor, constant: -8),
      sendButton.centerYAnchor.constraint(equalTo: textViewContainer.centerYAnchor),
      sendButton.widthAnchor.constraint(equalToConstant: configuration.buttonSize.width),
      sendButton.heightAnchor.constraint(equalToConstant: configuration.buttonSize.height),
    ])
  }

  override public func setupInitialState() {
    super.setupInitialState()
  }

  // MARK: - Custom Layout Methods

  private func setupLiquidGlassEffect() {}

  private func setupCustomAnimations() {}

  private func setupGestureRecognizers() {}

  // MARK: - Button UI Customization

  private func customizeSendButton() {
    // Blue send button
    sendButton.backgroundColor = .systemBlue
    sendButton.layer.cornerRadius = configuration.buttonSize.width / 2
    sendButton.tintColor = .white

    // Add shadow
    sendButton.layer.shadowColor = UIColor.systemBlue.cgColor
    sendButton.layer.shadowOffset = CGSize(width: 0, height: 2)
    sendButton.layer.shadowRadius = 4
    sendButton.layer.shadowOpacity = 0.3

    // Update configuration for blue style
    var config = sendButton.configuration ?? UIButton.Configuration.plain()
    config.background.backgroundColor = .systemBlue
    config.baseForegroundColor = .white
    sendButton.configuration = config
  }

  private func customizePlusButton() {
    // Gray plus button
    attachmentButton.backgroundColor = .systemGray4
    attachmentButton.layer.cornerRadius = configuration.buttonSize.width / 2
    attachmentButton.tintColor = .systemGray

    // Add subtle shadow
    attachmentButton.layer.shadowColor = UIColor.systemGray.cgColor
    attachmentButton.layer.shadowOffset = CGSize(width: 0, height: 1)
    attachmentButton.layer.shadowRadius = 2
    attachmentButton.layer.shadowOpacity = 0.2

    // Update configuration for gray style
    var config = attachmentButton.configuration ?? UIButton.Configuration.plain()
    config.background.backgroundColor = .systemGray4
    config.baseForegroundColor = .systemGray
    attachmentButton.configuration = config
  }

  private func customizeTextViewContainer() {
    // Customize the red text view container (fallback for older iOS)
    textViewContainer.layer.cornerRadius = 20
    textViewContainer.layer.borderWidth = 1
    textViewContainer.layer.borderColor = UIColor.systemRed.withAlphaComponent(0.3).cgColor

    // Add subtle shadow to container
    textViewContainer.layer.shadowColor = UIColor.red.cgColor
    textViewContainer.layer.shadowOffset = CGSize(width: 0, height: 2)
    textViewContainer.layer.shadowRadius = 8
    textViewContainer.layer.shadowOpacity = 0.1
  }

  @available(iOS 26.0, *)
  private func customizeGlassTextViewContainer() {
    textViewContainer.layer.cornerRadius = 20
    textViewContainer.clipsToBounds = true

    // Add subtle shadow to container
    textViewContainer.layer.shadowColor = UIColor.black.cgColor
    textViewContainer.layer.shadowOffset = CGSize(width: 0, height: 4)
    textViewContainer.layer.shadowRadius = 12
    textViewContainer.layer.shadowOpacity = 0.15

  }

  // MARK: - Override Height Management (Optional)

  override func updateHeight() {
    super.updateHeight()
  }

  // MARK: - Override Button Animations (Optional)

  override func showSendButton() {
    super.showSendButton()
  }

  override func hideSendButton() {
    super.hideSendButton()
  }

  // MARK: - Lifecycle Methods

  override func didMoveToWindow() {
    super.didMoveToWindow()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
  }
}
