import InlineKit
import InlineUI
import SwiftUI

struct FakeChatView: View {
  @Binding var text: String
  @Binding var textViewHeight: CGFloat
  var peerId: Peer

  var body: some View {
    VStack {
      ScrollView {
        LazyVStack(spacing: 6) {
          ForEach(0 ..< 20) { i in
            let isOutgoing = Bool.random()
            let messageText = generateFakeMessage(index: i)
            let isLongMessage = messageText.count > 22 || messageText.contains("\n")

            MessageBubble(
              messageText: messageText,
              isOutgoing: isOutgoing,
              isLongMessage: isLongMessage
            )
          }
        }
        .padding(.vertical)
      }
      .defaultScrollAnchor(.bottom)

      MessageInputBar(
        text: $text,
        textViewHeight: $textViewHeight,
        peerId: peerId
      )
    }
  }

  private func generateFakeMessage(index: Int) -> String {
    let shortMessages = [
      "Hey! 👋",
      "Thanks!",
      "Sure thing",
      "Awesome! 🎉",
      "Got it",
      "Nice",
      "Yep!",
      "OK 👍",
      "Later!",
      "🔥",
      "😊",
    ]

    let mediumMessages = [
      "What do you think about the UI?",
      "The animations are super smooth!",
      "Can you test it out?",
      "Just pushed some updates.",
      "Working on it right now!",
      "Should we add custom themes?",
      "Let's meet tomorrow?",
      "Need your feedback on this.",
    ]

    let longMessages = [
      "I've been testing the app all morning and everything seems to be working great. The performance improvements are really noticeable! 🚀",
      "Just had a meeting with the team and they love the new features we added. Especially the encrypted file sharing - that's a game changer!\n\nShould we plan a release for next week?",
      "Found a small bug in the notification system, but don't worry - I'm already working on a fix. Should have it resolved by end of day. Keep you posted! 🛠️",
      "The user feedback from the beta testing has been incredibly positive. They particularly highlighted the intuitive interface and quick response times. Great job everyone! 🎉",
      "We need to discuss the upcoming features for Q3. I've prepared a document with some proposals.\n\nWhen are you free for a quick call?",
      "The analytics show that user engagement has increased by 45% since our last update. The new chat features are really making a difference! 📈",
    ]

    let random = Double.random(in: 0 ... 1)
    if random < 0.3 {
      return shortMessages.randomElement() ?? shortMessages[0]
    } else if random < 0.7 {
      return mediumMessages.randomElement() ?? mediumMessages[0]
    } else {
      return longMessages.randomElement() ?? longMessages[0]
    }
  }
}
