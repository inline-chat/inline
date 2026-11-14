import InlineKit
import SwiftUI
import UIKit

/// Commands the New Thread composer sends to its editor.
@MainActor
final class NewThreadTextController {
  fileprivate weak var textView: NewThreadUITextView?

  func focus() {
    textView?.becomeFirstResponder()
  }

  /// Types "@" at the cursor (with a space before it when needed) to open the mention list.
  func insertMentionTrigger() {
    guard let textView else { return }
    textView.becomeFirstResponder()
    let range = textView.selectedRange
    let text = textView.attributedText.string as NSString
    let needsSpace = range.location > 0 && range.location <= text.length
      && !(CharacterSet.whitespacesAndNewlines.contains(
        UnicodeScalar(text.character(at: range.location - 1)) ?? " "
      ))
    textView.insertPlain(needsSpace ? " @" : "@", replacing: range)
  }

  /// Replaces the open `@query` with `item`, or adds it at the cursor when nothing is being typed.
  func insert(_ item: MentionCompletionItem, text mentionText: String, replacing query: MentionRange?) {
    guard let textView else { return }
    let current = textView.attributedText ?? NSAttributedString()
    var range: NSRange
    var prefix = ""
    if let query, NSMaxRange(query.range) <= current.length {
      range = query.range
    } else {
      range = textView.selectedRange
      if range.location > current.length { range = NSRange(location: current.length, length: 0) }
      let string = current.string as NSString
      if range.location > 0,
         let scalar = UnicodeScalar(string.character(at: range.location - 1)),
         !CharacterSet.whitespacesAndNewlines.contains(scalar)
      {
        prefix = " "
      }
    }

    let base = textView.baseAttributes
    var mentionAttributes = base
    mentionAttributes[.foregroundColor] = textView.tintColor ?? .systemBlue
    var source = current
    if !prefix.isEmpty {
      let mutable = NSMutableAttributedString(attributedString: current)
      mutable.replaceCharacters(in: range, with: NSAttributedString(string: prefix, attributes: base))
      source = mutable
      range = NSRange(location: range.location + prefix.utf16.count, length: 0)
    }

    let detector = MentionDetector()
    let result: (newAttributedText: NSAttributedString, newCursorPosition: Int) = switch item {
      case let .user(user):
        detector.replaceMention(
          in: source, range: range, with: mentionText, userId: user.userInfo.user.id,
          mentionAttributes: mentionAttributes, trailingAttributes: base
        )
      case let .group(group):
        detector.replaceGroupMention(
          in: source, range: range, with: mentionText, groupId: group.id,
          mentionAttributes: mentionAttributes, trailingAttributes: base
        )
      case let .agent(agent):
        detector.replaceMention(
          in: source, range: range, with: mentionText, userId: agent.botUserId, agentId: agent.id,
          mentionAttributes: mentionAttributes, trailingAttributes: base
        )
    }
    textView.attributedText = result.newAttributedText
    textView.selectedRange = NSRange(location: result.newCursorPosition, length: 0)
    textView.typingAttributes = base
    textView.becomeFirstResponder()
    textView.notifyChange()
  }
}

/// A growing UIKit text view for the New Thread composer, so mentions keep their
/// attributes (SwiftUI's `TextField` can't carry them).
struct NewThreadTextView: UIViewRepresentable {
  static let font = UIFont.preferredFont(forTextStyle: .body)

  let controller: NewThreadTextController
  let initialText: NSAttributedString?
  let placeholder: String
  let minHeight: CGFloat
  let maxHeight: CGFloat
  let focusOnAppear: Bool
  let onChange: (NSAttributedString, Int?) -> Void
  let onSubmit: () -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(parent: self)
  }

  func makeUIView(context: Context) -> NewThreadUITextView {
    let view = NewThreadUITextView()
    view.delegate = context.coordinator
    view.placeholder = placeholder
    view.onSubmit = { context.coordinator.parent.onSubmit() }
    view.onChange = { [weak coordinator = context.coordinator] in coordinator?.report() }
    if let initialText, initialText.length > 0 {
      view.attributedText = initialText
      view.updatePlaceholder()
    }
    controller.textView = view
    if focusOnAppear {
      // As part of the sheet's presentation, so the keyboard rises with it.
      view.focusWhenInWindow = true
    }
    return view
  }

  func updateUIView(_ uiView: NewThreadUITextView, context: Context) {
    context.coordinator.parent = self
    controller.textView = uiView
  }

  func sizeThatFits(_ proposal: ProposedViewSize, uiView: NewThreadUITextView, context: Context) -> CGSize? {
    let width = proposal.width ?? 320
    let fitting = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
    let height = min(max(fitting, minHeight), maxHeight)
    let scrolls = fitting > maxHeight
    if uiView.isScrollEnabled != scrolls {
      DispatchQueue.main.async { uiView.isScrollEnabled = scrolls }
    }
    return CGSize(width: width, height: height)
  }

  @MainActor
  final class Coordinator: NSObject, UITextViewDelegate {
    var parent: NewThreadTextView

    init(parent: NewThreadTextView) {
      self.parent = parent
    }

    func report() {
      guard let textView = parent.controller.textView else { return }
      textView.updatePlaceholder()
      let cursor = textView.selectedRange.length == 0 ? textView.selectedRange.location : nil
      parent.onChange(textView.attributedText ?? NSAttributedString(), cursor)
    }

    func textViewDidChange(_ textView: UITextView) {
      report()
    }

    func textViewDidChangeSelection(_ textView: UITextView) {
      report()
    }

    func textView(
      _ textView: UITextView,
      shouldChangeTextIn range: NSRange,
      replacementText text: String
    ) -> Bool {
      // Leave keyboards that compose text (Japanese, Chinese, Korean) alone mid-composition.
      guard let textView = textView as? NewThreadUITextView, textView.markedTextRange == nil else { return true }
      // Typing right after a mention must not continue its color.
      textView.typingAttributes = textView.baseAttributes

      // Editing inside a mention turns it back into plain text first.
      let attributed = textView.attributedText ?? NSAttributedString()
      let probe = text.isEmpty ? range.location : max(range.location - 1, 0)
      guard range.length > 0 || !text.isEmpty, probe < attributed.length else { return true }
      var effective = NSRange()
      let attributes = attributed.attributes(at: probe, effectiveRange: &effective)
      guard attributes[.mentionUserId] != nil || attributes[.mentionGroupId] != nil else { return true }
      // Typing at the mention's end is ordinary text after it.
      if !text.isEmpty, range.location >= NSMaxRange(effective) { return true }

      let mutable = NSMutableAttributedString(attributedString: attributed)
      let plain = NSAttributedString(
        string: (attributed.string as NSString).substring(with: effective),
        attributes: textView.baseAttributes
      )
      mutable.replaceCharacters(in: effective, with: plain)
      mutable.replaceCharacters(in: range, with: NSAttributedString(string: text, attributes: textView.baseAttributes))
      textView.attributedText = mutable
      textView.selectedRange = NSRange(location: range.location + text.utf16.count, length: 0)
      report()
      return false
    }
  }
}

final class NewThreadUITextView: UITextView {
  var placeholder = "" {
    didSet { placeholderLabel.text = placeholder }
  }

  var onSubmit: (() -> Void)?
  var onChange: (() -> Void)?
  var focusWhenInWindow = false

  private let placeholderLabel = UILabel()

  var baseAttributes: [NSAttributedString.Key: Any] {
    [.font: NewThreadTextView.font, .foregroundColor: UIColor.label]
  }

  init() {
    super.init(frame: .zero, textContainer: nil)
    backgroundColor = .clear
    font = NewThreadTextView.font
    adjustsFontForContentSizeCategory = true
    typingAttributes = baseAttributes
    textContainerInset = UIEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
    textContainer.lineFragmentPadding = 0
    isScrollEnabled = false
    tintColor = ThemeManager.shared.selected.accent
    setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    accessibilityIdentifier = "newThreadComposerText"

    placeholderLabel.font = NewThreadTextView.font
    placeholderLabel.adjustsFontForContentSizeCategory = true
    placeholderLabel.textColor = .placeholderText
    placeholderLabel.numberOfLines = 0
    placeholderLabel.isAccessibilityElement = false
    placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
    addSubview(placeholderLabel)
    NSLayoutConstraint.activate([
      placeholderLabel.topAnchor.constraint(equalTo: topAnchor, constant: textContainerInset.top),
      placeholderLabel.leadingAnchor.constraint(equalTo: frameLayoutGuide.leadingAnchor),
      placeholderLabel.trailingAnchor.constraint(equalTo: frameLayoutGuide.trailingAnchor),
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    if focusWhenInWindow, window != nil {
      focusWhenInWindow = false
      becomeFirstResponder()
    }
  }

  func updatePlaceholder() {
    placeholderLabel.isHidden = !(attributedText?.length == 0)
  }

  func insertPlain(_ string: String, replacing range: NSRange) {
    let mutable = NSMutableAttributedString(attributedString: attributedText ?? NSAttributedString())
    let safe = NSRange(location: min(range.location, mutable.length), length: 0)
    mutable.replaceCharacters(in: safe, with: NSAttributedString(string: string, attributes: baseAttributes))
    attributedText = mutable
    selectedRange = NSRange(location: safe.location + string.utf16.count, length: 0)
    typingAttributes = baseAttributes
    notifyChange()
  }

  func notifyChange() {
    updatePlaceholder()
    onChange?()
  }

  // Hardware Return follows the compose setting; Shift-Return adds a line.
  override var keyCommands: [UIKeyCommand]? {
    guard INUserSettings.current.compose.sendWithReturnOnIPad else { return super.keyCommands }
    let send = UIKeyCommand(input: "\r", modifierFlags: [], action: #selector(sendWithReturn))
    send.wantsPriorityOverSystemBehavior = true
    return (super.keyCommands ?? []) + [send]
  }

  @objc private func sendWithReturn() {
    onSubmit?()
  }
}
