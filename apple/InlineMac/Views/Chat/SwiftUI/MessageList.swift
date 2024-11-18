import InlineKit
import InlineUI
import SwiftUI

struct MessageList: View {
  @EnvironmentObject var fullChat: FullChatViewModel

  var body: some View {
    ScrollView {
      LazyVStack(pinnedViews: [.sectionFooters]) {
        ForEach(fullChat.messagesInSections) { section in
          Section(footer: DateBadge(date: section.date).flippedUpsideDown()) {
            ForEach(section.messages) { fullMessage in
              MessageView(fullMessage: fullMessage)
                .flippedUpsideDown()
                .id(fullMessage.id)
            }
          }
        }
      }
    }
    .flippedUpsideDown()
  }
}
