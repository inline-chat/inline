import InlineKit
import Logger
import TextProcessing
import UIKit
import UniformTypeIdentifiers

protocol StandaloneComposeTextViewDelegate: AnyObject {
  func composeTextViewDidChange(_ textView: StandaloneComposeTextView)
  func composeTextView(_ textView: StandaloneComposeTextView, didReceiveImage image: UIImage)
}

class StandaloneComposeTextView: UITextView {
  // MARK: - Properties

  weak var composeDelegate: StandaloneComposeTextViewDelegate?
  private var placeholderLabel: UILabel?
  private var bodyFont: UIFont { ChatTypography.font(17, compatibleWith: traitCollection) }

  // MARK: - Initialization

  override init(frame: CGRect, textContainer: NSTextContainer?) {
    super.init(frame: frame, textContainer: textContainer)
    setupTextView()
    setupPlaceholder()
    setupNotifications()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }

  // MARK: - Setup

  private func setupTextView() {
    backgroundColor = .clear
    allowsEditingTextAttributes = true
    font = bodyFont
    typingAttributes[.font] = font
    adjustsFontForContentSizeCategory = true
    textContainerInset = UIEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
    translatesAutoresizingMaskIntoConstraints = false
    tintColor = ThemeManager.shared.selected.accent
  }

  private func setupPlaceholder() {
    let label = UILabel()
    label.text = "Write a message"
    label.font = bodyFont
    label.adjustsFontForContentSizeCategory = true
    label.textColor = .secondaryLabel
    label.translatesAutoresizingMaskIntoConstraints = false
    label.textAlignment = .left
    addSubview(label)

    NSLayoutConstraint.activate([
      label.leadingAnchor.constraint(
        equalTo: leadingAnchor,
        constant: textContainer.lineFragmentPadding + textContainerInset.left
      ),
      label.topAnchor.constraint(equalTo: topAnchor, constant: textContainerInset.top),
    ])

    placeholderLabel = label
  }

  private func setupNotifications() {
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(textDidChange),
      name: UITextView.textDidChangeNotification,
      object: self
    )
  }

  // MARK: - Text Change Handling

  @objc private func textDidChange() {
    showPlaceholder(text.isEmpty)
    composeDelegate?.composeTextViewDidChange(self)

    // Handle sticker detection if needed
    if text.contains("￼") || attributedText.string.contains("￼") {
      handleStickerDetection()
    }

    fixFontSizeAfterStickerInsertion()
  }

  // MARK: - Placeholder Management

  func showPlaceholder(_ show: Bool) {
    placeholderLabel?.alpha = show ? 1 : 0
  }

  func setPlaceholderText(_ text: String) {
    placeholderLabel?.text = text
  }

  // MARK: - Paste Handling

  override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
    if action == #selector(paste(_:)), isEditable,
       ExperimentalFeatureFlags.richMessageCopyEditingEnabled, MessageTextPasteboard.containsFormattedText() {
      return true
    }
    return super.canPerformAction(action, withSender: sender)
  }

  override func paste(_ sender: Any?) {
    if let image = UIPasteboard.general.image {
      composeDelegate?.composeTextView(self, didReceiveImage: image)
    } else if let string = (ExperimentalFeatureFlags.richMessageCopyEditingEnabled ? MessageTextPasteboard.markdown() : nil)
      ?? UIPasteboard.general.string {
      if ExperimentalFeatureFlags.richMessageCopyEditingEnabled {
        // Keep Markdown markers visible while preserving the surrounding draft and native undo.
        typingAttributes = [.font: bodyFont, .foregroundColor: UIColor.label]
        insertText(string)
      } else {
        text = (text as NSString).replacingCharacters(in: selectedRange, with: string)
      }
      fixFontSizeAfterStickerInsertion()
      showPlaceholder(text.isEmpty)
      composeDelegate?.composeTextViewDidChange(self)
    } else {
      super.paste(sender)
      fixFontSizeAfterStickerInsertion()
      showPlaceholder(text.isEmpty)
      composeDelegate?.composeTextViewDidChange(self)
    }
  }

  // MARK: - Font and Sticker Handling

  private func fixFontSizeAfterStickerInsertion() {
    guard let attributedText = attributedText?.mutableCopy() as? NSMutableAttributedString,
          attributedText.length > 0
    else {
      return
    }

    var needsFix = false
    attributedText.enumerateAttribute(
      .font,
      in: NSRange(location: 0, length: attributedText.length),
      options: []
    ) { value, _, stop in
      if let font = value as? UIFont, font.pointSize != bodyFont.pointSize {
        needsFix = true
        stop.pointee = true
      }
    }

    if needsFix {
      attributedText.addAttribute(
        .font,
        value: bodyFont,
        range: NSRange(location: 0, length: attributedText.length)
      )
      attributedText.addAttribute(
        .foregroundColor,
        value: UIColor.label,
        range: NSRange(location: 0, length: attributedText.length)
      )

      self.attributedText = attributedText
    }
  }

  private func handleStickerDetection() {
    // Basic sticker detection - can be expanded as needed
    let fullText = attributedText.string
    let components = fullText.components(separatedBy: "￼")

    let isLikelyVoiceToSpeech = components.count == 2 &&
      (components[0].isEmpty || components[1].isEmpty) &&
      !hasValidStickerAttributes()

    if !isLikelyVoiceToSpeech {
      // Handle sticker if needed
      Log.shared.debug("Sticker detected in standalone text view")
    }
  }

  private func hasValidStickerAttributes() -> Bool {
    guard let attributedText else { return false }

    var hasValidSticker = false
    attributedText.enumerateAttribute(
      .attachment,
      in: NSRange(location: 0, length: attributedText.length),
      options: []
    ) { value, _, _ in
      if let attachment = value as? NSTextAttachment {
        if attachment.image != nil ||
          (attachment.fileWrapper?.regularFileContents != nil)
        {
          hasValidSticker = true
        }
      }
    }

    return hasValidSticker
  }

  // MARK: - Public Interface

  func clear() {
    text = ""
    showPlaceholder(true)
  }

  func setText(_ text: String) {
    self.text = text
    showPlaceholder(text.isEmpty)
  }
}
