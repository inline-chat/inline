@testable import InlineIOS
@testable import InlineKit
import InlineIOSUI
import InlineTheme
import InlineUI
import Testing
import TextProcessing
import UIKit

@Suite("Message emoji reactions on iPhone", .serialized)
@MainActor
struct MessageEmojiReactionDeviceTests {
  @Test("Production picker ordering, skin tones, learned emoji and both renderers",
        arguments: [nil, "🎉", "🧠", "👍🏽", "🐈‍⬛"] as [String?])
  func pickerMatrix(learnedEmoji: String?) throws {
    let defaults = UserDefaults.standard
    let keys = [EmojiSkinTonePreferenceStore.key,
                "chat.inline.reactionPicker.emojiUsageCounts.v1"]
    let original = keys.map { defaults.object(forKey: $0) }
    defer {
      for (key, value) in zip(keys, original) {
        if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
      }
    }
    defaults.set(["🧠": 20], forKey: keys[1])
    if let learnedEmoji {
      ReactionPickerEmojiUsageStore.recordPick(learnedEmoji)
    }
    let originalCounts = ReactionPickerEmojiUsageStore.usageCounts()
    let cases: [(String?, [String])] = [
      (nil, []), ("", []), ("hello سلام 123 #tag *", []),
      ("great work 🎉", ["🎉"]), ("🎉🔥🎉", ["🎉", "🔥"]),
      ("سلام ❤️ دنیا 🚀\n❤️", ["❤️", "🚀"]),
      ("👍 👍🏽 👩🏾‍💻 🇮🇷 👨‍👩‍👧‍👦", ["👍", "👍🏽", "👩🏾‍💻", "🇮🇷", "👨‍👩‍👧‍👦"]),
      ("1️⃣ #️⃣ *️⃣", ["1️⃣", "#️⃣", "*️⃣"]),
      ("❤︎ ☀︎ © ™", []), ("❤ ❤️ ©️ ™️", ["❤", "❤️", "©️", "™️"]),
      ("😀😃😄😁😆😅😂🤣🥲🥹😊😇🙂🙃😉😌", Array("😀😃😄😁😆😅😂🤣🥲🥹😊😇🙂🙃😉").map(String.init)),
    ]
    let database = AppDatabase.empty()
    let publisher = MessagesPublisher(database: database)
    let model = MessagesSectionedViewModel(
      peer: .user(id: 9_007), reversed: true,
      initialState: .init(messages: [], loadedWindowMetadata: MessagesProgressiveViewModel.unknownLoadedWindowMetadata(for: [])),
      database: database, publisher: publisher
    )
    defer { model.dispose() }
    var full = try #require(MessageView2PlaygroundFixtures.scenarios.first).message
    var checked = 0
    for implementation: MessageViewImplementation in [.legacy, .v2] {
      let list = MessagesCollectionView(
        peerId: .user(id: 9_007), chatId: 9_007, spaceId: nil, isPreview: true,
        theme: ThemeManager.shared.snapshot(variant: .light), viewModel: model,
        messageViewImplementation: implementation
      )
      for tone in EmojiSkinTone.allCases {
        EmojiSkinTonePreferenceStore.set(tone)
        var seen = Set<String>()
        let usual = ReactionPickerEmojiUsageStore.suggestedEmojis().map { tone.applying(to: $0) }
          .filter { seen.insert($0).inserted }
        for (text, messageEmojis) in cases {
          full.message.text = text
          let picker = list.reactionPickerForTesting(for: full)
          let buttons = descendants(of: picker).compactMap { $0 as? UIButton }
          var expected = messageEmojis
          for emoji in usual where !expected.contains(emoji) { expected.append(emoji) }
          expected = Array(expected.prefix(ReactionPickerEmojis.defaultLimit))
          #expect(buttons.map { $0.configuration?.title ?? "" } == expected,
                  "renderer=\(implementation) tone=\(tone) text=\(text ?? "nil")")
          #expect(buttons.map(\.accessibilityLabel) == expected.map(Optional.some))
          #expect(Set(expected).count == expected.count)
          #expect(buttons.allSatisfy { $0.isEnabled && $0.allControlEvents.contains(.touchUpInside) })
          #expect(descendants(of: picker).contains { $0 is UIScrollView })
          #expect(ReactionPickerEmojiUsageStore.usageCounts() == originalCounts)
          checked += 1
        }
      }
    }
    Attachment.record("Validated \(checked) production UIKit picker combinations; no reaction requests sent.",
                      named: "message-emoji-picker-matrix.txt")
  }

  private func descendants(of view: UIView) -> [UIView] {
    view.subviews.flatMap { [$0] + descendants(of: $0) }
  }
}
