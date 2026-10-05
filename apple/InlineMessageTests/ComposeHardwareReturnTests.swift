@testable import InlineIOS
@testable import InlineKit
@testable import TextProcessing
import GRDB
import Testing
import UIKit

@Suite("iPad hardware Return preference", .serialized)
@MainActor
struct ComposeHardwareReturnTests {
  private let sendSelector = NSSelectorFromString("sendWithHardwareReturn:")
  private let newlineSelector = NSSelectorFromString("insertHardwareNewline:")

  @Test("Return commands default on for iPad and respect the local setting", arguments: [UIUserInterfaceIdiom.pad, .phone])
  func commandsRespectPreference(idiom: UIUserInterfaceIdiom) throws {
    let fixture = try makeFixture()
    defer { fixture.restore() }
    fixture.textView.traitOverrides.userInterfaceIdiom = idiom
    #expect((command(in: fixture.textView, action: sendSelector) != nil) == (idiom == .pad))
    INUserSettings.current.compose.sendWithReturnOnIPad = false
    #expect(command(in: fixture.textView, action: sendSelector) == nil)
    INUserSettings.current.compose.sendWithReturnOnIPad = true
    let send = command(in: fixture.textView, action: sendSelector)
    #expect((send != nil) == (idiom == .pad))
    let newline = command(in: fixture.textView, action: newlineSelector)
    if idiom == .pad {
      #expect(send?.modifierFlags == [])
      #expect(send?.wantsPriorityOverSystemBehavior == true)
      #expect(newline?.modifierFlags == .shift)
    } else {
      #expect(newline == nil)
    }
    fixture.textView.isEditable = false
    #expect(command(in: fixture.textView, action: sendSelector) == nil)
  }

  @Test("Hardware Return uses the existing Send and Save entry point", arguments: [false, true])
  func sendAndEditUseExistingEntryPoint(editing: Bool) throws {
    let fixture = try makeFixture(enabled: true)
    defer { fixture.restore() }
    let peer = Peer.user(id: 9_105_021)
    let previous = ChatState.shared.states[peer]
    defer { ChatState.shared.states[peer] = previous }
    fixture.compose.peerId = peer
    fixture.compose.chatId = 9_105_021
    ChatState.shared.states[peer] = .init(editingMessageId: editing ? -21 : nil)
    fixture.textView.text = "Ready to send or save"
    let send = try #require(command(in: fixture.textView, action: sendSelector))
    _ = fixture.textView.perform(sendSelector, with: send)
    #expect(fixture.compose.submitCount == 1)
    #expect(fixture.compose.editingAtSubmission == editing)
    #expect(fixture.textView.text == "Ready to send or save")
  }

  @Test("Shift-Return inserts a normal newline through UIKit and its delegate")
  func shiftReturnInsertsText() throws {
    let fixture = try makeFixture(enabled: true)
    defer { fixture.restore() }
    let delegate = HardwareReturnTextDelegate()
    fixture.textView.delegate = delegate
    fixture.textView.text = "first"
    fixture.textView.selectedRange = NSRange(location: 5, length: 0)
    let newline = try #require(command(in: fixture.textView, action: newlineSelector))
    _ = fixture.textView.perform(newlineSelector, with: newline)
    #expect(fixture.textView.text == "first\n")
    #expect(delegate.replacements == ["\n"])
    #expect(delegate.changeCount == 1)
    #expect(fixture.compose.submitCount == 0)
  }

  @Test("Marked text retains Return and stale commands cannot submit")
  func markedTextPreventsSubmission() throws {
    let fixture = try makeFixture(enabled: true)
    defer { fixture.restore() }
    let send = try #require(command(in: fixture.textView, action: sendSelector))
    fixture.textView.setMarkedText("候補", selectedRange: NSRange(location: 2, length: 0))
    _ = try #require(fixture.textView.markedTextRange)
    #expect(command(in: fixture.textView, action: sendSelector) == nil)
    #expect(!fixture.textView.canPerformAction(sendSelector, withSender: send))
    _ = fixture.textView.perform(sendSelector, with: send)
    #expect(fixture.compose.submitCount == 0)
    #expect(fixture.textView.markedTextRange != nil)
  }

  @Test("Ordinary newline and multiline text insertion never submit", arguments: ["\n", "first\nsecond\n"])
  func ordinaryTextInsertionNeverSubmits(text: String) throws {
    let fixture = try makeFixture(enabled: true)
    defer { fixture.restore() }
    fixture.textView.insertText(text)
    #expect(fixture.textView.text == text)
    #expect(fixture.compose.submitCount == 0)
  }

  @Test("Return completes the actual emoji menu before attempting Send")
  func autocompleteHasPriority() async throws {
    let fixture = try makeFixture(enabled: true)
    defer { fixture.restore() }
    let host = UIViewController()
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 600, height: 800))
    window.rootViewController = host
    host.view.addSubview(fixture.textView)
    fixture.textView.frame = CGRect(x: 20, y: 400, width: 400, height: 80)
    window.isHidden = false
    defer {
      fixture.compose.autocompleteManager?.cleanup()
      fixture.compose.autocompleteManager = nil
      fixture.textView.resignFirstResponder()
      window.isHidden = true
    }
    #expect(fixture.textView.becomeFirstResponder())
    let database = try AppDatabase(DatabaseQueue())
    let manager = ComposeAutocompleteManager(database: database, chatId: -21, peerId: .user(id: -21), spaceId: nil)
    fixture.compose.autocompleteManager = manager
    manager.attachTo(textView: fixture.textView, anchorView: fixture.textView, parentView: host.view)
    fixture.textView.text = ":smile"
    fixture.textView.selectedRange = NSRange(location: 6, length: 0)
    #expect(manager.handleTextChange(in: fixture.textView))
    let menu = try #require(host.view.subviews.compactMap { $0 as? ComposeAutocompleteCompletionView }.first)
    for _ in 0..<100 where !menu.canSelectItems { await Task.yield() }
    #expect(menu.canSelectItems)
    let send = try #require(command(in: fixture.textView, action: sendSelector))
    _ = fixture.textView.perform(sendSelector, with: send)
    #expect(fixture.textView.text != ":smile")
    #expect(!fixture.textView.text.contains("\n"))
    #expect(fixture.compose.submitCount == 0)
  }

  private func command(in view: ComposeTextView, action: Selector) -> UIKeyCommand? {
    view.keyCommands?.first { $0.action == action }
  }

  private func makeFixture(
    enabled: Bool? = nil
  ) throws -> HardwareReturnFixture {
    let suiteName = "ComposeHardwareReturnTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    let previousSettings = INUserSettings.current
    let settings = INUserSettings(
      userDefaults: defaults,
      currentUserID: { nil },
      fetchNotificationSettings: { nil },
      saveNotificationSettings: { _ in Issue.record("Unexpected server settings save") }
    )
    INUserSettings.current = settings
    if let enabled { settings.compose.sendWithReturnOnIPad = enabled }
    let drafts = Drafts()
    let persistence = DraftPersistenceClient(
      registerIntent: { drafts.registerIntent(for: $0, kind: $1) },
      isLatestIntent: { drafts.isLatestIntent($0) },
      update: { _, _, _, _ in true }, clear: { _, _ in true }
    )
    let compose = HardwareReturnComposeView(
      frame: .zero,
      draftManager: DraftManager(debounceDelay: 2, persistence: persistence)
    )
    let textView = compose.textView
    textView.traitOverrides.userInterfaceIdiom = .pad
    let savedChatStates = UserDefaults.standard.object(forKey: "chatStates")
    return HardwareReturnFixture(compose: compose, textView: textView) {
      compose.removeObservers()
      INUserSettings.current = previousSettings
      defaults.removePersistentDomain(forName: suiteName)
      if let savedChatStates {
        UserDefaults.standard.set(savedChatStates, forKey: "chatStates")
      } else {
        UserDefaults.standard.removeObject(forKey: "chatStates")
      }
    }
  }
}

@MainActor
private struct HardwareReturnFixture {
  let compose: HardwareReturnComposeView
  let textView: ComposeTextView
  let restore: () -> Void
}

@MainActor
private final class HardwareReturnComposeView: ComposeView {
  private(set) var submitCount = 0
  private(set) var editingAtSubmission = false

  override func sendTapped() {
    submitCount += 1
    editingAtSubmission = peerId.map { ChatState.shared.getState(peer: $0).editingMessageId != nil } ?? false
  }
}

@MainActor
private final class HardwareReturnTextDelegate: NSObject, UITextViewDelegate {
  private(set) var replacements: [String] = []
  private(set) var changeCount = 0

  func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
    replacements.append(text)
    return true
  }

  func textViewDidChange(_ textView: UITextView) {
    changeCount += 1
  }
}
