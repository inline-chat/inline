import Foundation
import Testing

@testable import TextProcessing

@Suite("ComposeAutoPairEditing")
struct ComposeAutoPairEditingTests {
  @Test("typing an opening parenthesis inserts the closing parenthesis and leaves cursor between")
  func typingOpeningParenthesisInsertsPair() {
    let result = applyInsertion("(", to: "", cursor: 0)

    #expect(result?.text == "()")
    #expect(result?.selectedRange == NSRange(location: 1, length: 0))
  }

  @Test("typing an opening bracket inserts the closing bracket and leaves cursor between")
  func typingOpeningBracketInsertsPair() {
    let result = applyInsertion("[", to: "", cursor: 0)

    #expect(result?.text == "[]")
    #expect(result?.selectedRange == NSRange(location: 1, length: 0))
  }

  @Test("typing nested opening brackets nests the generated pairs")
  func typingNestedOpeningBracketsNestsPairs() {
    let first = applyInsertion("[", to: "", cursor: 0)
    let second = first.flatMap { applyInsertion("[", to: $0.text, cursor: $0.selectedRange.location) }

    #expect(second?.text == "[[]]")
    #expect(second?.selectedRange == NSRange(location: 2, length: 0))
  }

  @Test("typing an opening pair preserves surrounding text")
  func openingPairPreservesSurroundingText() {
    let result = applyInsertion("(", to: "a b", cursor: 2)

    #expect(result?.text == "a ()b")
    #expect(result?.selectedRange == NSRange(location: 3, length: 0))
  }

  @Test("typing a closing parenthesis before the same next character skips over it")
  func typingClosingParenthesisSkipsNextMatch() {
    let result = applyInsertion(")", to: "()", cursor: 1)

    #expect(result?.text == "()")
    #expect(result?.selectedRange == NSRange(location: 2, length: 0))
  }

  @Test("typing a closing bracket before the same next character skips over it")
  func typingClosingBracketSkipsNextMatch() {
    let result = applyInsertion("]", to: "[]", cursor: 1)

    #expect(result?.text == "[]")
    #expect(result?.selectedRange == NSRange(location: 2, length: 0))
  }

  @Test("typing a closing character does not skip when the immediate next character differs")
  func closingCharacterDoesNotSkipMismatch() {
    let replacement = ComposeAutoPairEditing.insertionReplacement(
      in: "(]",
      selectedRange: NSRange(location: 1, length: 0),
      insertedText: ")"
    )

    #expect(replacement == nil)
  }

  @Test("typing an opening pair over selected text falls back to normal replacement")
  func openingPairDoesNotWrapSelection() {
    let replacement = ComposeAutoPairEditing.insertionReplacement(
      in: "hello",
      selectedRange: NSRange(location: 1, length: 3),
      insertedText: "("
    )

    #expect(replacement == nil)
  }

  @Test("backspace between an auto pair deletes both characters")
  func deletingBetweenPairDeletesBoth() {
    let result = applyDeletion(to: "[]", cursor: 1)

    #expect(result?.text == "")
    #expect(result?.selectedRange == NSRange(location: 0, length: 0))
  }

  @Test("backspace between parentheses deletes both characters")
  func deletingBetweenParenthesesDeletesBoth() {
    let result = applyDeletion(to: "()", cursor: 1)

    #expect(result?.text == "")
    #expect(result?.selectedRange == NSRange(location: 0, length: 0))
  }

  @Test("backspace between a nested pair deletes the inner pair only")
  func deletingNestedPairDeletesInnerPair() {
    let result = applyDeletion(to: "[[]]", cursor: 2)

    #expect(result?.text == "[]")
    #expect(result?.selectedRange == NSRange(location: 1, length: 0))
  }

  @Test("backspace does not pair-delete mismatched characters")
  func deletingMismatchFallsBack() {
    let replacement = ComposeAutoPairEditing.deletionReplacement(
      in: "(]",
      selectedRange: NSRange(location: 1, length: 0)
    )

    #expect(replacement == nil)
  }

  private func applyInsertion(
    _ insertedText: String,
    to text: String,
    cursor: Int
  ) -> (text: String, selectedRange: NSRange)? {
    guard let replacement = ComposeAutoPairEditing.insertionReplacement(
      in: text,
      selectedRange: NSRange(location: cursor, length: 0),
      insertedText: insertedText
    ) else {
      return nil
    }

    return ComposeAutoPairEditing.apply(replacement, to: text)
  }

  private func applyDeletion(
    to text: String,
    cursor: Int
  ) -> (text: String, selectedRange: NSRange)? {
    guard let replacement = ComposeAutoPairEditing.deletionReplacement(
      in: text,
      selectedRange: NSRange(location: cursor, length: 0)
    ) else {
      return nil
    }

    return ComposeAutoPairEditing.apply(replacement, to: text)
  }
}
