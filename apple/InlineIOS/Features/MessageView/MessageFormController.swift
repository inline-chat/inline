import InlineKit
import InlineMessageLayout
import enum InlineProtocol.AgentGrantRequirement
import struct InlineProtocol.BlockForm
import struct InlineProtocol.BlockFormField
import struct InlineProtocol.BlockFormNumber
import struct InlineProtocol.BlockFormSelect
import struct InlineProtocol.BlockFormText
import struct InlineProtocol.BlockText
import UIKit

/// Taps in a bot form drawn as a card: picks, toggles, the editor for typed answers, and the
/// one submit. Answers go to `MessageFormDraftStore`; `onChange` asks the message to rebuild
/// so the card shows them. Nothing is sent until submit, and then as one direct RPC.
@MainActor
enum MessageFormController {
  static func handle(_ tap: RichFormTap, message: Message, from view: UIView, onChange: @escaping () -> Void) {
    switch tap {
    case let .select(formID, fieldID, optionID):
      guard let (field, key) = openField(formID, fieldID, in: message), case let .select(select)? = field.kind else { return }
      UISelectionFeedbackGenerator().selectionChanged()
      let value = MessageFormAnswers.selecting(optionID, in: select, from: MessageFormAnswers.value(field, key: key))
      MessageFormDraftStore.shared.setValue(value, key: key, fieldID: fieldID)
      onChange()
    case let .toggle(formID, fieldID):
      guard let (field, key) = openField(formID, fieldID, in: message) else { return }
      UISelectionFeedbackGenerator().selectionChanged()
      var isOn = false
      if case let .toggle(value)? = MessageFormAnswers.value(field, key: key) { isOn = value }
      MessageFormDraftStore.shared.setValue(.toggle(!isOn), key: key, fieldID: fieldID)
      onChange()
    case let .edit(formID, fieldID):
      guard let (field, key) = openField(formID, fieldID, in: message) else { return }
      edit(field, key: key, message: message, from: view, onChange: onChange)
    case let .submit(formID):
      submit(formID, message: message, from: view, onChange: onChange)
    }
  }

  /// Why the viewer can't answer, when the form needs a grant they lack.
  static func disabledReason(_ form: BlockForm, message: Message) -> String? {
    let requirement = form.requiredGrant
    guard requirement != .none else { return nil }
    let botUserID = message.fromId
    AgentGrantStore.shared.ensureLoaded(botUserID: botUserID)
    let access = AgentGrantStore.shared.access(botUserID: botUserID)
    return MessageActionPresentation.disabledReason(
      requirement: requirement,
      access: access,
      ownerName: access.flatMap { ObjectCache.shared.getCachedUser(id: $0.ownerUserID)?.user.firstName },
      botName: ObjectCache.shared.getCachedUser(id: botUserID)?.user.firstName
    )
  }

  static func format(_ value: Double, integer: Bool) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    formatter.maximumFractionDigits = integer ? 0 : 6
    return formatter.string(from: NSNumber(value: value)) ?? String(value)
  }

  // MARK: Fields

  /// The field and its draft key, while the form still takes answers.
  private static func openField(_ formID: String, _ fieldID: String, in message: Message) -> (BlockFormField, MessageFormDraftStore.Key)? {
    guard let form = MessageFormAnswers.form(formID, in: message), !form.closed,
          let field = form.fields.first(where: { $0.fieldID == fieldID })
    else { return nil }
    let key = MessageFormDraftStore.Key(message: message, formID: formID)
    guard MessageFormDraftStore.shared.phase(key) == .editing else { return nil }
    return (field, key)
  }

  private static func text(_ range: BlockText, in message: Message) -> String {
    let source = (message.text ?? "") as NSString
    guard range.offset >= 0, range.length > 0, range.offset + range.length <= Int64(source.length) else { return "" }
    return source.substring(with: NSRange(location: Int(range.offset), length: Int(range.length)))
  }

  private static func edit(
    _ field: BlockFormField,
    key: MessageFormDraftStore.Key,
    message: Message,
    from view: UIView,
    onChange: @escaping () -> Void
  ) {
    let title = text(field.label, in: message)
    let detail = field.hasDescription_p ? text(field.description_p, in: message) : nil
    let value = MessageFormAnswers.value(field, key: key)
    let store = MessageFormDraftStore.shared
    switch field.kind {
    case let .select(select)?:
      var other = ""
      if case let .selection(_, text)? = value { other = text ?? "" }
      let editOther = {
        let editor = MessageFormFieldEditor(title: title, detail: detail, kind: .singleLine, text: other, placeholder: "Your answer") { text in
          // Re-read: the answer may have changed while the editor was open.
          store.setValue(MessageFormAnswers.withOther(text, in: select, from: MessageFormAnswers.value(field, key: key)), key: key, fieldID: field.fieldID)
          onChange()
        }
        present(editor.wrapped(), from: view)
      }
      guard MessageFormAnswers.usesMenu(select) else {
        editOther()
        return
      }
      let sheet = UIAlertController(title: title, message: detail, preferredStyle: .actionSheet)
      for option in select.options {
        var label = text(option.label, in: message)
        if option.recommended { label += " (Recommended)" }
        sheet.addAction(UIAlertAction(title: label, style: .default) { _ in
          store.setValue(.selection([option.optionID], other: nil), key: key, fieldID: field.fieldID)
          onChange()
        })
      }
      if select.allowOther {
        sheet.addAction(UIAlertAction(title: "Other…", style: .default) { _ in editOther() })
      }
      sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
      sheet.popoverPresentationController?.sourceView = view
      sheet.popoverPresentationController?.sourceRect = view.bounds
      present(sheet, from: view)
    case let .text(text)?:
      var current = ""
      // A secret answer is never shown back, even from a draft.
      if text.kind != .secret, case let .text(string)? = value { current = string }
      let kind: MessageFormFieldEditor.Kind = switch text.kind {
      case .multiline: .multiline
      case .secret: .secret
      case .singleLine, .UNRECOGNIZED: .singleLine
      }
      let editor = MessageFormFieldEditor(
        title: title,
        detail: detail,
        kind: kind,
        text: current,
        placeholder: text.hasPlaceholder ? text.placeholder : nil,
        maxLength: text.hasMaxLength && text.maxLength > 0 ? Int(text.maxLength) : nil
      ) { answer in
        store.setValue(.text(answer), key: key, fieldID: field.fieldID)
        onChange()
      }
      present(editor.wrapped(), from: view)
    case let .number(number)?:
      var current = ""
      if case let .number(value)? = value { current = format(value, integer: number.integer) }
      let editor = MessageFormFieldEditor(
        title: title,
        detail: detail,
        kind: .number(
          minimum: number.hasMin ? number.min : nil,
          maximum: number.hasMax ? number.max : nil,
          integer: number.integer
        ),
        text: current,
        placeholder: nil
      ) { answer in
        let parsed = MessageFormFieldEditor.parse(answer)
        store.setValue(parsed.map { .number($0) }, key: key, fieldID: field.fieldID)
        onChange()
      }
      present(editor.wrapped(), from: view)
    case .toggle?, nil:
      break
    }
  }

  // MARK: Submit

  private static func submit(_ formID: String, message: Message, from view: UIView, onChange: @escaping () -> Void) {
    guard let form = MessageFormAnswers.form(formID, in: message), !form.closed else { return }
    let key = MessageFormDraftStore.Key(message: message, formID: formID)
    let store = MessageFormDraftStore.shared
    guard store.phase(key) == .editing else { return }
    if let reason = disabledReason(form, message: message) {
      alert(reason, from: view)
      return
    }
    let answers: [MessageFormAnswers.Answer]
    switch MessageFormAnswers.submission(form, key: key) {
    case let .missing(_, label):
      alert("Answer “\(text(label, in: message))” first", from: view)
      return
    case let .ready(ready):
      answers = ready
    }
    let loadingKey = MessageActionInteractionState.LoadingKey(
      peerId: message.peerId,
      messageId: message.messageId,
      rev: message.rev,
      actionId: formID
    )
    guard MessageActionInteractionState.shared.begin(key: loadingKey) else { return }
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
    store.setPhase(.submitting, key: key)
    onChange()
    let generation = store.generation
    Task { @MainActor [weak view] in
      do {
        let interactionID = try await MessageFormSubmitter.submit(
          message: message,
          formID: formID,
          values: answers.map { ($0.fieldID, $0.value) }
        )
        // The account changed while sending: nothing here belongs to it.
        guard store.generation == generation else { return }
        MessageActionInteractionState.shared.attachInteractionId(interactionID, for: loadingKey)
        // Keeps the sent answers on the card, secrets excepted.
        store.markSubmitted(key, secretFieldIDs: MessageFormAnswers.secretFieldIDs(form))
      } catch {
        guard store.generation == generation else { return }
        MessageActionInteractionState.shared.fail(key: loadingKey)
        store.setPhase(.editing, key: key)
        if let view { alert(error.localizedDescription, from: view) }
      }
      onChange()
    }
  }

  // MARK: Presenting

  private static func alert(_ text: String, from view: UIView) {
    let controller = UIAlertController(title: text, message: nil, preferredStyle: .alert)
    controller.addAction(UIAlertAction(title: "OK", style: .default))
    present(controller, from: view)
  }

  private static func present(_ controller: UIViewController, from view: UIView) {
    var presenter = view.window?.rootViewController
    while let presented = presenter?.presentedViewController, !presented.isBeingDismissed {
      presenter = presented
    }
    presenter?.present(controller, animated: true)
  }
}

// MARK: - Editor

/// A sheet for one typed answer: a line, several lines, a secret or a number. Done saves;
/// Cancel leaves the answer as it was.
final class MessageFormFieldEditor: UIViewController, UITextFieldDelegate, UITextViewDelegate {
  enum Kind {
    case singleLine
    case multiline
    case secret
    case number(minimum: Double?, maximum: Double?, integer: Bool)
  }

  private let kind: Kind
  private let initialText: String
  private let placeholder: String?
  private let detail: String?
  private let maxLength: Int?
  private let onDone: (String) -> Void
  private let field = UITextField()
  private let textView = UITextView()
  private let footnote = UILabel()

  init(
    title: String,
    detail: String?,
    kind: Kind,
    text: String,
    placeholder: String?,
    maxLength: Int? = nil,
    onDone: @escaping (String) -> Void
  ) {
    self.kind = kind
    initialText = text
    self.placeholder = placeholder
    self.detail = detail?.isEmpty == false ? detail : nil
    self.maxLength = maxLength
    self.onDone = onDone
    super.init(nibName: nil, bundle: nil)
    self.title = title
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  /// In a navigation controller, as a sheet that starts at half height.
  func wrapped() -> UIViewController {
    let navigation = UINavigationController(rootViewController: self)
    if let sheet = navigation.sheetPresentationController {
      sheet.detents = [.medium(), .large()]
      sheet.prefersGrabberVisible = true
    }
    return navigation
  }

  private var isMultiline: Bool { if case .multiline = kind { true } else { false } }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemGroupedBackground
    navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .cancel, primaryAction: UIAction { [weak self] _ in
      self?.dismiss(animated: true)
    })
    let done = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in self?.finish() })
    done.style = .done
    navigationItem.rightBarButtonItem = done

    let input: UIView
    if isMultiline {
      textView.text = initialText
      textView.font = .preferredFont(forTextStyle: .body)
      textView.adjustsFontForContentSizeCategory = true
      textView.backgroundColor = .secondarySystemGroupedBackground
      textView.layer.cornerRadius = 10
      textView.textContainerInset = UIEdgeInsets(top: 10, left: 8, bottom: 10, right: 8)
      textView.delegate = self
      textView.heightAnchor.constraint(greaterThanOrEqualToConstant: 140).isActive = true
      input = textView
    } else {
      field.text = initialText
      field.placeholder = placeholder ?? (isNumber ? "Number" : "Your answer")
      field.font = .preferredFont(forTextStyle: .body)
      field.adjustsFontForContentSizeCategory = true
      field.borderStyle = .none
      field.backgroundColor = .secondarySystemGroupedBackground
      field.layer.cornerRadius = 10
      field.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 12, height: 1))
      field.leftViewMode = .always
      field.clearButtonMode = .whileEditing
      field.returnKeyType = .done
      field.delegate = self
      field.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
      switch kind {
      case .secret:
        field.isSecureTextEntry = true
        field.textContentType = .password
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
      case let .number(minimum, _, integer):
        // The number pads have no minus key.
        let allowsNegative = (minimum ?? -1) < 0
        field.keyboardType = allowsNegative ? .numbersAndPunctuation : (integer ? .numberPad : .decimalPad)
      case .singleLine, .multiline:
        break
      }
      input = field
    }
    footnote.font = .preferredFont(forTextStyle: .footnote)
    footnote.adjustsFontForContentSizeCategory = true
    footnote.textColor = .secondaryLabel
    footnote.numberOfLines = 0
    footnote.text = detail ?? rangeHint
    footnote.isHidden = footnote.text?.isEmpty ?? true

    let stack = UIStackView(arrangedSubviews: [input, footnote])
    stack.axis = .vertical
    stack.spacing = 8
    stack.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(stack)
    let guide = view.readableContentGuide
    NSLayoutConstraint.activate([
      stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
      stack.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
    ])
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    if isMultiline { textView.becomeFirstResponder() } else { field.becomeFirstResponder() }
  }

  private var isNumber: Bool { if case .number = kind { true } else { false } }

  private var rangeHint: String? {
    guard case let .number(minimum, maximum, integer) = kind else { return nil }
    let kind = integer ? "A whole number" : "A number"
    switch (minimum, maximum) {
    case let (minimum?, maximum?):
      return "\(kind) from \(MessageFormController.format(minimum, integer: integer)) to \(MessageFormController.format(maximum, integer: integer))."
    case let (minimum?, nil):
      return "\(kind), at least \(MessageFormController.format(minimum, integer: integer))."
    case let (nil, maximum?):
      return "\(kind), at most \(MessageFormController.format(maximum, integer: integer))."
    case (nil, nil):
      return integer ? "\(kind)." : nil
    }
  }

  /// A number typed in the viewer's locale, or plain digits.
  static func parse(_ text: String) -> Double? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    return formatter.number(from: trimmed)?.doubleValue ?? Double(trimmed)
  }

  private func finish() {
    let text = isMultiline ? textView.text ?? "" : field.text ?? ""
    if case let .number(minimum, maximum, integer) = kind, !text.trimmingCharacters(in: .whitespaces).isEmpty {
      guard let value = Self.parse(text),
            !integer || value.rounded() == value,
            minimum.map({ value >= $0 }) ?? true,
            maximum.map({ value <= $0 }) ?? true
      else {
        footnote.text = rangeHint ?? "Enter a number."
        footnote.textColor = .systemRed
        footnote.isHidden = false
        UINotificationFeedbackGenerator().notificationOccurred(.error)
        return
      }
    }
    onDone(text)
    dismiss(animated: true)
  }

  func textFieldShouldReturn(_ textField: UITextField) -> Bool {
    finish()
    return false
  }

  func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
    guard let maxLength else { return true }
    let current = (textField.text ?? "") as NSString
    return current.replacingCharacters(in: range, with: string).count <= maxLength
  }

  func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
    guard let maxLength else { return true }
    let current = (textView.text ?? "") as NSString
    return current.replacingCharacters(in: range, with: text).count <= maxLength
  }
}
