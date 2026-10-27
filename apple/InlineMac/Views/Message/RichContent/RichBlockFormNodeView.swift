import AppKit
import InlineKit
import InlineProtocol
import TextProcessing

/// A bot form (`BlockForm`): native controls laid out from the planned
/// frames, answers kept in `MessageFormDraftStore`, one submit. Secret
/// answers are never shown back and never persisted.
final class RichBlockFormNodeView: RichBlockRenderableView, NSTextFieldDelegate, NSTextViewDelegate {
  /// One per choice field: AppKit groups radio buttons that share a
  /// superview and action, so each field's options need their own parent.
  private final class ChoiceContainer: NSView {
    override var isFlipped: Bool { true }
  }

  private final class FieldControls {
    var container: NSView?
    var buttons: [(id: String, button: NSButton)] = []
    var otherButton: NSButton?
    var otherField: NSTextField?
    var popUp: NSPopUpButton?
    var textField: NSTextField?
    var textView: NSTextView?
    var scrollView: NSScrollView?
    var toggle: NSSwitch?
    var stepper: NSStepper?
    var descriptions: [RichBlockTextSurface] = []
    var views: [NSView] = []
  }

  private var pool: [RichBlockTextSurface] = []
  private var controls: [String: FieldControls] = [:]
  private var structure: [RichBlockFormNode.Field] = []
  private var node: RichBlockFormNode?
  private var message: InlineKit.Message?
  private var draftKey: MessageFormDraftStore.Key?
  private var disabledReason: String?
  private let submitButton: NSButton = {
    let button = NSButton(title: "", target: nil, action: nil)
    button.bezelStyle = .push
    button.controlSize = .regular
    return button
  }()

  private let reasonField: NSTextField = {
    let field = NSTextField(labelWithString: "")
    field.font = .systemFont(ofSize: 11)
    field.textColor = .secondaryLabelColor
    field.lineBreakMode = .byTruncatingTail
    return field
  }()

  private let spinner: NSProgressIndicator = {
    let view = NSProgressIndicator()
    view.style = .spinning
    view.controlSize = .small
    view.isDisplayedWhenStopped = false
    return view
  }()

  override var orderedTextSurfaces: [RichBlockTextSurface] { pool.filter { !$0.isHidden } }

  init() {
    super.init(reuseKind: .form)
    addSubview(submitButton)
    addSubview(reasonField)
    addSubview(spinner)
    submitButton.target = self
    submitButton.action = #selector(submit)
    setAccessibilityRole(.group)
    setAccessibilityLabel(String(localized: "Form"))
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  // MARK: Apply

  override func apply(node: RichBlockLayoutPlan.Node, context: RichBlockRenderContext) {
    guard case let .form(form) = node.kind else { return }
    let message = context.relatedMessage
    let key = MessageFormDraftStore.Key(message: message, formID: form.formID)
    // A closed form keeps no answers, secrets included.
    if form.closed {
      MessageFormDraftStore.shared.discard(key)
    }
    // Rebuild controls only when the questions change, so a streamed edit of
    // the surrounding text never drops what the viewer is typing.
    if draftKey != key || structure != form.fields {
      rebuildControls(for: form, context: context, key: key)
    }
    self.node = form
    self.message = message
    draftKey = key
    structure = form.fields
    applyText(form, context: context)
    applySubmitState(form, context: context)
    needsLayout = true
  }

  override func updateLayout(node: RichBlockLayoutPlan.Node) {
    guard case let .form(form) = node.kind else { return }
    self.node = form
    needsLayout = true
  }

  private func applyText(_ form: RichBlockFormNode, context: RichBlockRenderContext) {
    var index = 0
    func surface() -> RichBlockTextSurface {
      defer { index += 1 }
      if index < pool.count {
        pool[index].isHidden = false
        return pool[index]
      }
      let surface = RichBlockTextSurface(frame: .zero)
      addSubview(surface)
      pool.append(surface)
      return surface
    }
    if let title = form.title {
      surface().apply(
        text: context.text(title, role: .heading(level: 4), isRTL: form.isRTL, maximumWidth: form.titleFrame?.width),
        linkColor: context.palette.link,
        onEntityClick: context.interactions.onTextEntityClick
      )
    }
    for field in form.fields {
      let label = NSMutableAttributedString(attributedString: context.text(field.label, role: .paragraph, isRTL: form.isRTL))
      PlatformFontTraits.applyBaseFont(
        ChatTypography.current.font(sized: context.baseFontSize, weight: .medium),
        to: label
      )
      if field.required {
        label.append(NSAttributedString(string: " *", attributes: [
          .font: ChatTypography.current.font(sized: context.baseFontSize),
          .foregroundColor: context.palette.tertiary,
        ]))
      }
      surface().apply(text: label, linkColor: context.palette.link, onEntityClick: context.interactions.onTextEntityClick)
      if let description = field.description {
        surface().apply(
          text: context.text(description, role: .footer, isRTL: form.isRTL),
          linkColor: context.palette.link,
          onEntityClick: context.interactions.onTextEntityClick
        )
      }
    }
    for extra in pool.dropFirst(index) { extra.isHidden = true }
  }

  private func applySubmitState(_ form: RichBlockFormNode, context: RichBlockRenderContext) {
    let requirement = InlineProtocol.AgentGrantRequirement(rawValue: form.requiredGrant) ?? .none
    let botUserID = context.relatedMessage.fromId
    if requirement != .none { AgentGrantStore.shared.ensureLoaded(botUserID: botUserID) }
    let access = AgentGrantStore.shared.access(botUserID: botUserID)
    disabledReason = MessageActionPresentation.disabledReason(
      requirement: requirement,
      access: access,
      ownerName: access.flatMap { ObjectCache.shared.getCachedUser(id: $0.ownerUserID)?.user.firstName },
      botName: ObjectCache.shared.getCachedUser(id: botUserID)?.user.firstName
    )
    let phase = draftKey.map { MessageFormDraftStore.shared.phase($0) } ?? .editing
    let isLocked = form.closed || phase != .editing
    switch (form.closed, phase) {
    case (true, _): submitButton.title = String(localized: "Answered")
    case (_, .submitted): submitButton.title = String(localized: "Sent")
    default: submitButton.title = form.submitLabel
    }
    submitButton.keyEquivalent = ""
    submitButton.bezelColor = isLocked ? nil : .controlAccentColor
    submitButton.isEnabled = !isLocked && disabledReason == nil
    reasonField.stringValue = isLocked ? "" : (disabledReason ?? "")
    reasonField.isHidden = reasonField.stringValue.isEmpty
    if phase == .submitting { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
    setControlsEnabled(!isLocked && disabledReason == nil)
  }

  // MARK: Controls

  private func rebuildControls(for form: RichBlockFormNode, context: RichBlockRenderContext, key: MessageFormDraftStore.Key) {
    for field in controls.values {
      field.views.forEach { $0.removeFromSuperview() }
      field.descriptions.forEach { $0.removeFromSuperview() }
    }
    controls.removeAll()
    let drafts = MessageFormDraftStore.shared
    for field in form.fields {
      let built = FieldControls()
      let draft = drafts.value(key, fieldID: field.id)
      switch field.control {
      case let .choices(options, multiple, defaults, otherFrame):
        var selected = Set(defaults)
        var otherText: String?
        if case let .selection(ids, other)? = draft {
          selected = Set(ids)
          otherText = other
        }
        let container = ChoiceContainer(frame: .zero)
        addSubview(container)
        built.container = container
        built.views.append(container)
        for option in options {
          let title = context.plainString(option.label)
          let button = multiple
            ? NSButton(checkboxWithTitle: title, target: self, action: #selector(choiceChanged(_:)))
            : NSButton(radioButtonWithTitle: title, target: self, action: #selector(choiceChanged(_:)))
          button.state = selected.contains(option.id) ? .on : .off
          button.identifier = NSUserInterfaceItemIdentifier(field.id)
          container.addSubview(button)
          built.buttons.append((option.id, button))
          if let description = option.description, description.length > 0 {
            let surface = RichBlockTextSurface(frame: .zero)
            surface.apply(
              text: context.text(description, role: .footer, isRTL: form.isRTL),
              linkColor: context.palette.link,
              onEntityClick: context.interactions.onTextEntityClick
            )
            container.addSubview(surface)
            built.descriptions.append(surface)
          }
        }
        if otherFrame != nil {
          let title = String(localized: "Other")
          let button = multiple
            ? NSButton(checkboxWithTitle: title, target: self, action: #selector(choiceChanged(_:)))
            : NSButton(radioButtonWithTitle: title, target: self, action: #selector(choiceChanged(_:)))
          button.identifier = NSUserInterfaceItemIdentifier(field.id)
          button.state = otherText != nil ? .on : .off
          let other = makeTextField(secret: false, placeholder: String(localized: "Your answer"))
          other.stringValue = otherText ?? ""
          other.identifier = NSUserInterfaceItemIdentifier(field.id)
          container.addSubview(button)
          container.addSubview(other)
          built.otherButton = button
          built.otherField = other
        }
      case let .menu(options, defaults, otherFrame):
        let popUp = NSPopUpButton(frame: .zero, pullsDown: false)
        popUp.addItem(withTitle: String(localized: "Choose…"))
        popUp.lastItem?.representedObject = nil
        for option in options {
          popUp.addItem(withTitle: context.plainString(option.label))
          popUp.lastItem?.representedObject = option.id
        }
        if otherFrame != nil {
          popUp.menu?.addItem(.separator())
          popUp.addItem(withTitle: String(localized: "Other"))
          popUp.lastItem?.representedObject = "\u{0}other"
        }
        var selectedID = defaults.first
        var otherText: String?
        if case let .selection(ids, other)? = draft {
          selectedID = ids.first
          otherText = other
        }
        let index = popUp.itemArray.firstIndex {
          ($0.representedObject as? String) == (otherText != nil ? "\u{0}other" : selectedID)
        }
        popUp.selectItem(at: index ?? 0)
        popUp.identifier = NSUserInterfaceItemIdentifier(field.id)
        popUp.target = self
        popUp.action = #selector(choiceChanged(_:))
        addSubview(popUp)
        built.popUp = popUp
        built.views.append(popUp)
        if otherFrame != nil {
          let other = makeTextField(secret: false, placeholder: String(localized: "Your answer"))
          other.stringValue = otherText ?? ""
          other.identifier = NSUserInterfaceItemIdentifier(field.id)
          addSubview(other)
          built.otherField = other
          built.views.append(other)
        }
      case let .text(kind, placeholder, defaultValue, _):
        var value = defaultValue ?? ""
        if case let .text(draftValue)? = draft { value = draftValue }
        if kind == .multiline {
          let scroll = NSTextView.scrollableTextView()
          scroll.borderType = .bezelBorder
          scroll.hasVerticalScroller = true
          if let textView = scroll.documentView as? NSTextView {
            textView.isRichText = false
            textView.font = .systemFont(ofSize: NSFont.systemFontSize)
            textView.string = value
            textView.delegate = self
            textView.identifier = NSUserInterfaceItemIdentifier(field.id)
            built.textView = textView
          }
          addSubview(scroll)
          built.scrollView = scroll
          built.views.append(scroll)
        } else {
          let textField = makeTextField(secret: kind == .secret, placeholder: placeholder)
          // Secret answers are never shown back, even from a draft.
          textField.stringValue = kind == .secret ? "" : value
          textField.identifier = NSUserInterfaceItemIdentifier(field.id)
          addSubview(textField)
          built.textField = textField
          built.views.append(textField)
        }
      case let .toggle(defaultValue):
        let toggle = NSSwitch()
        var isOn = defaultValue
        if case let .toggle(value)? = draft { isOn = value }
        toggle.state = isOn ? .on : .off
        toggle.controlSize = .small
        toggle.identifier = NSUserInterfaceItemIdentifier(field.id)
        toggle.target = self
        toggle.action = #selector(toggleChanged(_:))
        addSubview(toggle)
        built.toggle = toggle
        built.views.append(toggle)
      case let .number(defaultValue, minimum, maximum, step, integer):
        let textField = makeTextField(secret: false, placeholder: nil)
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = integer ? 0 : 6
        if let minimum { formatter.minimum = NSNumber(value: minimum) }
        if let maximum { formatter.maximum = NSNumber(value: maximum) }
        textField.formatter = formatter
        var value = defaultValue
        if case let .number(draftValue)? = draft { value = draftValue }
        if let value { textField.doubleValue = value }
        textField.identifier = NSUserInterfaceItemIdentifier(field.id)
        let stepper = NSStepper()
        stepper.minValue = minimum ?? -Double(Int32.max)
        stepper.maxValue = maximum ?? Double(Int32.max)
        stepper.increment = step ?? 1
        stepper.valueWraps = false
        stepper.doubleValue = value ?? 0
        stepper.identifier = NSUserInterfaceItemIdentifier(field.id)
        stepper.target = self
        stepper.action = #selector(stepperChanged(_:))
        addSubview(textField)
        addSubview(stepper)
        built.textField = textField
        built.stepper = stepper
        built.views += [textField, stepper]
      }
      controls[field.id] = built
    }
  }

  private func makeTextField(secret: Bool, placeholder: String?) -> NSTextField {
    let field: NSTextField = secret ? NSSecureTextField() : NSTextField()
    field.placeholderString = placeholder
    field.bezelStyle = .roundedBezel
    field.controlSize = .regular
    field.font = .systemFont(ofSize: NSFont.systemFontSize)
    field.delegate = self
    return field
  }

  private func setControlsEnabled(_ enabled: Bool) {
    for field in controls.values {
      field.buttons.forEach { $0.button.isEnabled = enabled }
      field.otherButton?.isEnabled = enabled
      field.otherField?.isEnabled = enabled
      field.popUp?.isEnabled = enabled
      field.textField?.isEnabled = enabled
      field.textView?.isEditable = enabled
      field.toggle?.isEnabled = enabled
      field.stepper?.isEnabled = enabled
    }
  }

  // MARK: Layout

  override func layout() {
    super.layout()
    guard let node else { return }
    var surfaces = pool.filter { !$0.isHidden }.makeIterator()
    if let titleFrame = node.titleFrame { surfaces.next()?.frame = titleFrame }
    for field in node.fields {
      surfaces.next()?.frame = field.labelFrame
      if let descriptionFrame = field.descriptionFrame { surfaces.next()?.frame = descriptionFrame }
      guard let built = controls[field.id] else { continue }
      let frame = field.controlFrame
      switch field.control {
      case let .choices(options, _, _, otherFrame):
        built.container?.frame = frame
        var descriptions = built.descriptions.makeIterator()
        for (option, entry) in zip(options, built.buttons) {
          let optionFrame = option.frame
          entry.button.frame = CGRect(x: optionFrame.minX, y: optionFrame.minY, width: optionFrame.width, height: 18)
          if let description = option.description, description.length > 0 {
            descriptions.next()?.frame = CGRect(
              x: optionFrame.minX + RichBlockAgentMetrics.formChoiceIndent,
              y: optionFrame.minY + 18,
              width: max(1, optionFrame.width - RichBlockAgentMetrics.formChoiceIndent),
              height: max(0, optionFrame.height - 18)
            )
          }
        }
        if let other = otherFrame {
          built.otherButton?.frame = CGRect(x: other.minX, y: other.minY + 3, width: 70, height: 18)
          built.otherField?.frame = CGRect(x: other.minX + 72, y: other.minY, width: max(80, other.width - 72), height: other.height)
        }
      case let .menu(_, _, otherFrame):
        built.popUp?.frame = CGRect(x: frame.minX - 2, y: frame.minY, width: frame.width, height: RichBlockAgentMetrics.formControlHeight)
        if let otherFrame {
          built.otherField?.frame = otherFrame.offsetBy(dx: frame.minX, dy: frame.minY)
        }
      case .text:
        built.scrollView?.frame = frame
        built.textField?.frame = frame
      case .toggle:
        built.toggle?.frame = CGRect(x: frame.minX, y: frame.minY + 2, width: 38, height: 20)
      case .number:
        built.textField?.frame = CGRect(x: frame.minX, y: frame.minY, width: min(140, frame.width - 22), height: frame.height)
        built.stepper?.frame = CGRect(x: frame.minX + min(140, frame.width - 22) + 4, y: frame.minY, width: 18, height: frame.height)
      }
    }
    let submit = node.submitFrame
    let buttonWidth = max(84, ceil(submitButton.intrinsicContentSize.width))
    submitButton.frame = CGRect(
      x: node.isRTL ? submit.maxX - buttonWidth : submit.minX - 6,
      y: submit.minY,
      width: buttonWidth,
      height: submit.height
    )
    spinner.frame = CGRect(x: submitButton.frame.maxX + 6, y: submit.midY - 8, width: 16, height: 16)
    reasonField.frame = CGRect(
      x: submitButton.frame.maxX + 8,
      y: submit.midY - 8,
      width: max(0, submit.maxX - submitButton.frame.maxX - 8),
      height: 16
    )
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    for field in controls.values {
      field.views.forEach { $0.removeFromSuperview() }
      field.descriptions.forEach { $0.removeFromSuperview() }
    }
    controls.removeAll()
    pool.forEach { $0.removeFromSuperview() }
    pool.removeAll()
    structure = []
    node = nil
    message = nil
    draftKey = nil
  }

  // MARK: Editing

  @objc private func choiceChanged(_ sender: NSControl) {
    guard let fieldID = sender.identifier?.rawValue else { return }
    // Radio buttons in one field are exclusive; AppKit only groups them by
    // shared action within one superview, so keep them in sync explicitly.
    if let button = sender as? NSButton, let built = controls[fieldID], !isMultiple(fieldID) {
      for entry in built.buttons where entry.button !== button { entry.button.state = .off }
      if built.otherButton !== button { built.otherButton?.state = .off }
    }
    saveDraft(fieldID)
  }

  @objc private func toggleChanged(_ sender: NSSwitch) {
    guard let fieldID = sender.identifier?.rawValue else { return }
    saveDraft(fieldID)
  }

  @objc private func stepperChanged(_ sender: NSStepper) {
    guard let fieldID = sender.identifier?.rawValue else { return }
    controls[fieldID]?.textField?.doubleValue = sender.doubleValue
    saveDraft(fieldID)
  }

  func controlTextDidChange(_ notification: Notification) {
    guard let field = notification.object as? NSTextField, let fieldID = field.identifier?.rawValue else { return }
    if let built = controls[fieldID], built.otherField === field, !field.stringValue.isEmpty {
      if !isMultiple(fieldID) {
        built.buttons.forEach { $0.button.state = .off }
        if let popUp = built.popUp { popUp.selectItem(at: popUp.numberOfItems - 1) }
      }
      built.otherButton?.state = .on
    }
    saveDraft(fieldID)
  }

  func textDidChange(_ notification: Notification) {
    guard let textView = notification.object as? NSTextView, let fieldID = textView.identifier?.rawValue else { return }
    saveDraft(fieldID)
  }

  private func isMultiple(_ fieldID: String) -> Bool {
    guard let field = node?.fields.first(where: { $0.id == fieldID }),
          case let .choices(_, multiple, _, _) = field.control
    else { return false }
    return multiple
  }

  private func saveDraft(_ fieldID: String) {
    guard let draftKey else { return }
    MessageFormDraftStore.shared.setValue(currentValue(fieldID), key: draftKey, fieldID: fieldID)
  }

  private func currentValue(_ fieldID: String) -> MessageFormDraftValue? {
    guard let field = node?.fields.first(where: { $0.id == fieldID }), let built = controls[fieldID] else { return nil }
    switch field.control {
    case .choices:
      let ids = built.buttons.filter { $0.button.state == .on }.map(\.id)
      let other = built.otherButton?.state == .on ? built.otherField?.stringValue : nil
      return .selection(ids, other: other)
    case .menu:
      let represented = built.popUp?.selectedItem?.representedObject as? String
      if represented == "\u{0}other" { return .selection([], other: built.otherField?.stringValue ?? "") }
      return .selection(represented.map { [$0] } ?? [], other: nil)
    case let .text(kind, _, _, maxLength):
      var value = kind == .multiline ? (built.textView?.string ?? "") : (built.textField?.stringValue ?? "")
      if let maxLength, value.count > maxLength { value = String(value.prefix(maxLength)) }
      return .text(value)
    case .toggle:
      return .toggle(built.toggle?.state == .on)
    case .number:
      guard let text = built.textField?.stringValue, !text.isEmpty else { return nil }
      return .number(built.textField?.doubleValue ?? 0)
    }
  }

  private func isEmpty(_ value: MessageFormDraftValue?) -> Bool {
    switch value {
    case nil: true
    case let .text(text)?: text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    case let .selection(ids, other)?: ids.isEmpty && (other?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    case .toggle?, .number?: false
    }
  }

  // MARK: Submit

  @objc private func submit() {
    guard let node, let message, let draftKey, !node.closed else { return }
    if let disabledReason {
      ToastCenter.shared.showInfo(disabledReason)
      return
    }
    guard MessageFormDraftStore.shared.phase(draftKey) == .editing else { return }
    var values: [(fieldID: String, value: MessageFormDraftValue)] = []
    for field in node.fields {
      let value = currentValue(field.id)
      if field.required, isEmpty(value) {
        let source = (message.text ?? "") as NSString
        let label = field.label.offset + field.label.length <= source.length
          ? source.substring(with: NSRange(location: field.label.offset, length: field.label.length))
          : ""
        ToastCenter.shared.showInfo(String(localized: "Answer “\(label)” first"))
        return
      }
      guard let value else { continue }
      if case .toggle = value {
        values.append((field.id, value))
      } else if !isEmpty(value) {
        values.append((field.id, value))
      }
    }
    let loadingKey = MessageActionInteractionState.LoadingKey(
      peerId: message.peerId,
      messageId: message.messageId,
      rev: message.rev,
      actionId: node.formID
    )
    guard MessageActionInteractionState.shared.begin(key: loadingKey) else { return }
    MessageFormDraftStore.shared.setPhase(.submitting, key: draftKey)
    refreshSubmitPresentation()
    let generation = MessageFormDraftStore.shared.generation
    Task { @MainActor [weak self] in
      do {
        let interactionID = try await MessageFormSubmitter.submit(
          message: message,
          formID: node.formID,
          values: values
        )
        // The account changed while sending: nothing here belongs to it.
        guard MessageFormDraftStore.shared.generation == generation else { return }
        MessageActionInteractionState.shared.attachInteractionId(interactionID, for: loadingKey)
        MessageFormDraftStore.shared.setPhase(.submitted, key: draftKey)
      } catch {
        guard MessageFormDraftStore.shared.generation == generation else { return }
        MessageActionInteractionState.shared.fail(key: loadingKey)
        MessageFormDraftStore.shared.setPhase(.editing, key: draftKey)
        ToastCenter.shared.showError(error.localizedDescription)
      }
      self?.refreshSubmitPresentation()
    }
  }

  private func refreshSubmitPresentation() {
    guard let node, let draftKey else { return }
    let phase = MessageFormDraftStore.shared.phase(draftKey)
    let isLocked = node.closed || phase != .editing
    switch (node.closed, phase) {
    case (true, _): submitButton.title = String(localized: "Answered")
    case (_, .submitted): submitButton.title = String(localized: "Sent")
    default: submitButton.title = node.submitLabel
    }
    submitButton.bezelColor = isLocked ? nil : .controlAccentColor
    submitButton.isEnabled = !isLocked && disabledReason == nil
    if phase == .submitting { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
    setControlsEnabled(!isLocked && disabledReason == nil)
    needsLayout = true
  }
}
