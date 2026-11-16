import Foundation
import InlineProtocol
import Testing
@testable import InlineKit

@Suite("Message form answers")
@MainActor
struct MessageFormAnswersTests {
  static func select(multiple: Bool, defaults: [String] = []) -> BlockFormSelect {
    .with {
      $0.multiple = multiple
      $0.defaultOptionIds = defaults
      $0.options = ["a", "b", "c"].map { id in BlockFormOption.with { $0.optionID = id } }
    }
  }

  static func message(_ form: BlockForm) -> InlineKit.Message {
    var message = InlineKit.Message(
      messageId: 7,
      fromId: 2,
      date: Date(timeIntervalSince1970: 0),
      text: "Questions",
      peerUserId: 1,
      peerThreadId: nil,
      chatId: 3
    )
    let child = Block.with { $0.form = form }
    let callout = Block.with { $0.callout = .with { $0.children = [child] } }
    message.blockContentPayload = BlockContentPayload(.with { $0.blocks = [callout] })
    return message
  }

  static func form() -> BlockForm {
    .with {
      $0.formID = "f"
      $0.fields = [
        .with {
          $0.fieldID = "pick"
          $0.required = true
          $0.label = .with { $0.offset = 0; $0.length = 4 }
          $0.select = select(multiple: false, defaults: ["missing", "b"])
        },
        .with {
          $0.fieldID = "secret"
          $0.text = .with { $0.kind = .secret; $0.defaultValue = "never" }
        },
        .with {
          $0.fieldID = "flag"
          $0.toggle = .with { $0.defaultValue = false }
        },
        .with {
          $0.fieldID = "note"
          $0.text = .with { $0.kind = .singleLine }
        },
      ]
    }
  }

  @Test("A single choice replaces the answer; a multiple choice adds and removes in the form's order")
  func selecting() {
    let single = Self.select(multiple: false)
    #expect(MessageFormAnswers.selecting("b", in: single, from: .selection(["a"], other: "x")) == .selection(["b"], other: nil))
    let multiple = Self.select(multiple: true)
    var value = MessageFormAnswers.selecting("c", in: multiple, from: nil)
    value = MessageFormAnswers.selecting("a", in: multiple, from: value)
    #expect(value == .selection(["a", "c"], other: nil))
    value = MessageFormAnswers.withOther("  mine ", in: multiple, from: value)
    #expect(value == .selection(["a", "c"], other: "mine"))
    value = MessageFormAnswers.selecting("c", in: multiple, from: value)
    #expect(value == .selection(["a"], other: "mine"))
  }

  @Test("An Other answer replaces a single choice; empty text removes it")
  func other() {
    let single = Self.select(multiple: false)
    #expect(MessageFormAnswers.withOther("mine", in: single, from: .selection(["a"], other: nil)) == .selection([], other: "mine"))
    #expect(MessageFormAnswers.withOther(" ", in: single, from: .selection([], other: "mine")) == .selection([], other: nil))
  }

  @Test("Answers fall back to defaults, never for secrets; unknown default options are dropped")
  func defaults() throws {
    let form = Self.form()
    let key = MessageFormDraftStore.Key(message: Self.message(form), formID: "f")
    MessageFormDraftStore.shared.discard(key)
    #expect(MessageFormAnswers.value(form.fields[0], key: key) == .selection(["b"], other: nil))
    #expect(MessageFormAnswers.value(form.fields[1], key: key) == nil)
    #expect(MessageFormAnswers.value(form.fields[2], key: key) == .toggle(false))
    MessageFormDraftStore.shared.setValue(.selection(["a"], other: nil), key: key, fieldID: "pick")
    #expect(MessageFormAnswers.value(form.fields[0], key: key) == .selection(["a"], other: nil))
    MessageFormDraftStore.shared.discard(key)
  }

  @Test("Submitting sends answered fields and toggles, and stops at an empty required question")
  func submission() {
    var form = Self.form()
    form.fields[0].select.defaultOptionIds = []
    let key = MessageFormDraftStore.Key(message: Self.message(form), formID: "f")
    MessageFormDraftStore.shared.discard(key)
    #expect(MessageFormAnswers.submission(form, key: key) == .missing(fieldID: "pick", label: form.fields[0].label))
    MessageFormDraftStore.shared.setValue(.selection(["c"], other: nil), key: key, fieldID: "pick")
    MessageFormDraftStore.shared.setValue(.text("  "), key: key, fieldID: "note")
    #expect(MessageFormAnswers.submission(form, key: key) == .ready([
      .init(fieldID: "pick", value: .selection(["c"], other: nil)),
      .init(fieldID: "flag", value: .toggle(false)),
    ]))
    MessageFormDraftStore.shared.discard(key)
  }

  @Test("A submitted form keeps the sent answers and drops secrets")
  func submittedKeepsAnswers() {
    let form = Self.form()
    let key = MessageFormDraftStore.Key(message: Self.message(form), formID: "f")
    let store = MessageFormDraftStore.shared
    store.discard(key)
    store.setValue(.selection(["a"], other: nil), key: key, fieldID: "pick")
    store.setValue(.text("hunter2"), key: key, fieldID: "secret")
    #expect(MessageFormAnswers.secretFieldIDs(form) == ["secret"])
    store.markSubmitted(key, secretFieldIDs: MessageFormAnswers.secretFieldIDs(form))
    #expect(store.phase(key) == .submitted)
    #expect(MessageFormAnswers.value(form.fields[0], key: key) == .selection(["a"], other: nil))
    #expect(store.value(key, fieldID: "secret") == nil)
    // Without the form, nothing is kept.
    store.setValue(.selection(["a"], other: nil), key: key, fieldID: "pick")
    store.markSubmitted(key, secretFieldIDs: nil)
    #expect(store.value(key, fieldID: "pick") == nil)
    store.discard(key)
  }

  @Test("A form is found inside other blocks")
  func find() {
    let message = Self.message(Self.form())
    #expect(MessageFormAnswers.form("f", in: message)?.fields.count == 4)
    #expect(MessageFormAnswers.form("g", in: message) == nil)
  }
}
