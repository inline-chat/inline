import InlineKit
import UIKit

final class ComposeView: UIView {
  // MARK: - Properties

  private let sendButton: UIButton = {
    let button = UIButton()
    let config = UIImage.SymbolConfiguration(pointSize: 24, weight: .semibold)
    let image = UIImage(systemName: "arrow.up.circle.fill", withConfiguration: config)
    button.setImage(image, for: .normal)
    button.tintColor = .systemBlue
    button.isHidden = true // Initially hidden
    return button
  }()

  private let textView: UITextView = {
    let storage = OptimizedTextStorage()
    let layoutManager = OptimizedLayoutManager()
    let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))

    container.widthTracksTextView = true
    container.heightTracksTextView = false
    container.lineFragmentPadding = 0

    layoutManager.addTextContainer(container)
    storage.addLayoutManager(layoutManager)

    let textView = UITextView(frame: .zero, textContainer: container)
    textView.backgroundColor = .clear
    textView.font = .preferredFont(forTextStyle: .body)
    textView.textContainerInset = UIEdgeInsets(top: 8, left: 4, bottom: 8, right: 4)
    textView.isScrollEnabled = true
    textView.autocorrectionType = .no
    textView.autocapitalizationType = .sentences
    textView.smartQuotesType = .no
    textView.smartDashesType = .no

    textView.layer.drawsAsynchronously = true
    textView.layer.shouldRasterize = true
    textView.layer.rasterizationScale = UIScreen.main.scale

    return textView
  }()

  private let placeholderLabel: UILabel = {
    let label = UILabel()
    label.text = "Write a message"
    label.font = .preferredFont(forTextStyle: .body)
    label.textColor = .tertiaryLabel

    return label
  }()

  private var heightConstraint: NSLayoutConstraint?
  var onTextChange: ((String) -> Void)?
  var onSend: (() -> Void)?

  // MARK: - Initialization

  override init(frame: CGRect) {
    super.init(frame: frame)
    setupViews()
    setupConstraints()
    setupTextView()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  // MARK: - Setup

  private func setupViews() {
    addSubview(textView)
    addSubview(placeholderLabel)
    addSubview(sendButton)

    textView.translatesAutoresizingMaskIntoConstraints = false
    placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
    sendButton.translatesAutoresizingMaskIntoConstraints = false

    sendButton.addTarget(self, action: #selector(handleSend), for: .touchUpInside)
  }

  private func setupConstraints() {
    let heightConstraint = textView.heightAnchor.constraint(equalToConstant: 40)
    self.heightConstraint = heightConstraint

    NSLayoutConstraint.activate([
      textView.topAnchor.constraint(equalTo: topAnchor),
      textView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
      textView.trailingAnchor.constraint(equalTo: sendButton.leadingAnchor, constant: -8),
      textView.bottomAnchor.constraint(equalTo: bottomAnchor),
      heightConstraint,

      placeholderLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
      placeholderLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

      sendButton.centerYAnchor.constraint(equalTo: centerYAnchor),
      sendButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
      sendButton.widthAnchor.constraint(equalToConstant: 32),
      sendButton.heightAnchor.constraint(equalToConstant: 32),
    ])
  }

  @objc private func handleSend() {
    onSend?()

    textView.text = ""
    updatePlaceholderVisibility()
    updateSendButtonVisibility()
    updateHeight()
    print("Send done")
  }

  private func setupTextView() {
    textView.delegate = self
  }

  // MARK: - Public Interface

  var text: String {
    get { textView.text }
    set {
      textView.text = newValue
      updatePlaceholderVisibility()
      updateSendButtonVisibility()
      updateHeight()
    }
  }

  // MARK: - Private Methods

  private func updatePlaceholderVisibility() {
    UIView.animate(withDuration: 0.2) {
      self.placeholderLabel.alpha = self.textView.text.isEmpty ? 1 : 0
    }
  }

  private func updateSendButtonVisibility() {
    let hasText = !textView.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    UIView.animate(withDuration: 0.2) {
      self.sendButton.isHidden = !hasText
      self.sendButton.alpha = hasText ? 1 : 0
    }
  }

  private func updateHeight() {
    let size = textView.sizeThatFits(
      CGSize(width: textView.bounds.width, height: CGFloat.greatestFiniteMagnitude))
    let newHeight = min(size.height, 300)

    guard heightConstraint?.constant != newHeight else { return }

    heightConstraint?.constant = newHeight

    UIView.animate(withDuration: 0.2) {
      self.superview?.layoutIfNeeded()
    }
  }
}

// MARK: - UITextViewDelegate

extension ComposeView: UITextViewDelegate {
  func textViewDidChange(_ textView: UITextView) {
    onTextChange?(textView.text)
    updatePlaceholderVisibility()
    updateSendButtonVisibility()
    updateHeight()
  }
}

// MARK: - OptimizedTextStorage & OptimizedLayoutManager

final class OptimizedTextStorage: NSTextStorage {
  private var storage = NSMutableAttributedString()

  override var string: String { storage.string }

  override func attributes(at location: Int, effectiveRange range: NSRangePointer?)
    -> [NSAttributedString.Key: Any]
  {
    storage.attributes(at: location, effectiveRange: range)
  }

  override func replaceCharacters(in range: NSRange, with str: String) {
    storage.replaceCharacters(in: range, with: str)
    edited(.editedCharacters, range: range, changeInLength: str.count - range.length)
  }

  override func setAttributes(_ attrs: [NSAttributedString.Key: Any]?, range: NSRange) {
    storage.setAttributes(attrs, range: range)
    edited(.editedAttributes, range: range, changeInLength: 0)
  }
}

final class OptimizedLayoutManager: NSLayoutManager {
  override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
    guard let textContainer = textContainers.first else { return }
    let visibleRect = textContainer.size
    let glyphRange = glyphRange(
      forBoundingRect: CGRect(origin: .zero, size: visibleRect),
      in: textContainer)
    super.drawGlyphs(forGlyphRange: glyphRange, at: origin)
  }
}
