import Foundation
import InlineProtocol

/// A bot form's answers as they stand: the viewer's draft, else the form's defaults. Shared by
/// clients that draw forms without keeping one live control per field (iOS draws them as card
/// rows and edits typed answers in a sheet).
public enum MessageFormAnswers {
  /// The form `formID` in `message`'s blocks, nested ones included.
  public static func form(_ formID: String, in message: Message) -> BlockForm? {
    guard let blocks = message.blockContentPayload?.content.blocks else { return nil }
    return find(formID, in: blocks, depth: 0)
  }

  private static func find(_ formID: String, in blocks: [Block], depth: Int) -> BlockForm? {
    guard depth <= 16 else { return nil }
    for block in blocks {
      let children: [Block]
      switch block.kind {
      case let .form(form)?:
        if form.formID == formID { return form }
        continue
      case let .list(list)?: children = list.items.flatMap(\.children)
      case let .quote(quote)?: children = quote.children
      case let .disclosure(disclosure)?: children = disclosure.children
      case let .callout(callout)?: children = callout.children
      case let .planProposal(plan)?: children = plan.children
      case let .approval(approval)?: children = approval.children
      default: continue
      }
      if let found = find(formID, in: children, depth: depth + 1) { return found }
    }
    return nil
  }

  /// IDs of `form`'s secret text fields, whose answers are never kept after submit.
  public static func secretFieldIDs(_ form: BlockForm) -> Set<String> {
    Set(form.fields.compactMap { field in
      if case let .text(text)? = field.kind, text.kind == .secret { field.fieldID } else { nil }
    })
  }

  /// Whether `field` is a single choice with too many options to list, picked from a menu.
  public static func usesMenu(_ select: BlockFormSelect) -> Bool {
    !select.multiple && select.options.count > 6
  }

  /// `field`'s answer: the draft, else its default. Secret fields have no default.
  @MainActor
  public static func value(_ field: BlockFormField, key: MessageFormDraftStore.Key) -> MessageFormDraftValue? {
    if let draft = MessageFormDraftStore.shared.value(key, fieldID: field.fieldID) { return draft }
    switch field.kind {
    case let .select(select)?:
      let ids = Set(select.options.map(\.optionID))
      let defaults = select.defaultOptionIds.filter(ids.contains)
      guard !defaults.isEmpty else { return nil }
      return .selection(select.multiple ? defaults : [defaults[0]], other: nil)
    case let .text(text)?:
      guard text.kind != .secret, text.hasDefaultValue, !text.defaultValue.isEmpty else { return nil }
      return .text(text.defaultValue)
    case let .toggle(toggle)?:
      return .toggle(toggle.defaultValue)
    case let .number(number)?:
      return number.hasDefaultValue ? .number(number.defaultValue) : nil
    case nil:
      return nil
    }
  }

  /// `value` after the viewer taps `optionID`: a single choice replaces the answer, a
  /// multiple choice adds or removes the option and keeps an "Other" answer.
  public static func selecting(_ optionID: String, in select: BlockFormSelect, from value: MessageFormDraftValue?) -> MessageFormDraftValue {
    guard select.multiple else { return .selection([optionID], other: nil) }
    var ids: [String] = []
    var other: String?
    if case let .selection(current, currentOther)? = value {
      ids = current
      other = currentOther
    }
    if let index = ids.firstIndex(of: optionID) {
      ids.remove(at: index)
    } else {
      // Keep the form's order, not the order tapped.
      ids = select.options.map(\.optionID).filter { $0 == optionID || ids.contains($0) }
    }
    return .selection(ids, other: other)
  }

  /// `value` with its "Other" answer set to `text`; empty text removes it.
  public static func withOther(_ text: String, in select: BlockFormSelect, from value: MessageFormDraftValue?) -> MessageFormDraftValue {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    var ids: [String] = []
    if select.multiple, case let .selection(current, _)? = value { ids = current }
    if trimmed.isEmpty {
      return .selection(ids, other: nil)
    }
    return .selection(select.multiple ? ids : [], other: trimmed)
  }

  public static func isEmpty(_ value: MessageFormDraftValue?) -> Bool {
    switch value {
    case nil: true
    case let .text(text)?: text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    case let .selection(ids, other)?: ids.isEmpty && (other?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    case .toggle?, .number?: false
    }
  }

  public enum Submission: Equatable, Sendable {
    case ready([Answer])
    /// A required question has no answer; its label is the field's text range.
    case missing(fieldID: String, label: BlockText)
  }

  public struct Answer: Equatable, Sendable {
    public let fieldID: String
    public let value: MessageFormDraftValue
  }

  /// What submitting `form` sends: every answered field, or the first required one left empty.
  @MainActor
  public static func submission(_ form: BlockForm, key: MessageFormDraftStore.Key) -> Submission {
    var answers: [Answer] = []
    for field in form.fields {
      let value = value(field, key: key)
      if field.required, isEmpty(value) {
        return .missing(fieldID: field.fieldID, label: field.label)
      }
      guard let value else { continue }
      if case .toggle = value {
        answers.append(Answer(fieldID: field.fieldID, value: value))
      } else if !isEmpty(value) {
        answers.append(Answer(fieldID: field.fieldID, value: value))
      }
    }
    return .ready(answers)
  }
}
