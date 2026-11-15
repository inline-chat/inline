import InlineKit
import InlineProtocol
import TextProcessing
import UIKit

/// Select Text for messages the menu can't select in place (code blocks, lists, tables and
/// other rich bodies): the message's text in a selectable text view, with Copy from the
/// system edit menu and Quote for the selection.
final class MessageSelectTextSheet: UIViewController, UITextViewDelegate {
  private let text: String
  private let entities: MessageEntities?
  private let onQuote: ((String) -> Void)?
  private let textView = UITextView()
  private lazy var quoteItem = UIBarButtonItem(
    title: String(localized: "Quote"),
    image: UIImage(systemName: "text.quote"),
    primaryAction: UIAction { [weak self] _ in self?.quoteSelection() }
  )

  init(text: String, entities: MessageEntities?, onQuote: ((String) -> Void)?) {
    self.text = text
    self.entities = entities
    self.onQuote = onQuote
    super.init(nibName: nil, bundle: nil)
    title = String(localized: "Select Text")
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  /// Wraps the sheet in a navigation controller, ready to present.
  static func make(text: String, entities: MessageEntities?, onQuote: ((String) -> Void)?) -> UIViewController {
    let navigation = UINavigationController(rootViewController: MessageSelectTextSheet(
      text: text,
      entities: entities,
      onQuote: onQuote
    ))
    if let sheet = navigation.sheetPresentationController {
      sheet.detents = [.medium(), .large()]
      sheet.prefersGrabberVisible = true
    }
    return navigation
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemBackground

    let configuration = ProcessEntities.Configuration(
      font: .preferredFont(forTextStyle: .body),
      primaryColor: .label,
      linkColor: ThemeManager.shared.selected.accent,
      convertMentionsToLink: false,
      renderPhoneNumbers: false
    )
    textView.attributedText = ProcessEntities.toAttributedString(
      text: text,
      entities: entities,
      configuration: configuration
    )
    textView.isEditable = false
    textView.isSelectable = true
    textView.adjustsFontForContentSizeCategory = true
    textView.alwaysBounceVertical = true
    textView.textContainerInset = UIEdgeInsets(top: 16, left: 16, bottom: 24, right: 16)
    textView.backgroundColor = .clear
    textView.delegate = self
    textView.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(textView)
    NSLayoutConstraint.activate([
      textView.topAnchor.constraint(equalTo: view.topAnchor),
      textView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      textView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      textView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])

    navigationItem.leftBarButtonItem = UIBarButtonItem(
      systemItem: .close,
      primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) }
    )
    if onQuote != nil {
      navigationItem.rightBarButtonItem = quoteItem
      quoteItem.isEnabled = false
    }
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    // Start with everything selected, so Copy or Quote is one tap and handles adjust it.
    textView.becomeFirstResponder()
    textView.selectAll(nil)
  }

  func textViewDidChangeSelection(_ textView: UITextView) {
    quoteItem.isEnabled = textView.selectedRange.length > 0
  }

  private func quoteSelection() {
    let range = textView.selectedRange
    guard range.length > 0, let onQuote else { return }
    let selected = (textView.attributedText.string as NSString).substring(with: range)
    dismiss(animated: true) {
      onQuote(selected)
    }
  }
}
