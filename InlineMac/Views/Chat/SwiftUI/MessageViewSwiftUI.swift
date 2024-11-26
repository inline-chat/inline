import InlineKit
import InlineUI
import SwiftUI

struct MessageView: View {
  // Props
  var fullMessage: FullMessage
  var showsSender: Bool = true
  
  // Computed
  var from: User {
    fullMessage.user ?? User.deletedInstance
  }

  var showsAvatar: Bool { showsSender }
  var showsName: Bool { showsSender }
  
  var message: Message {
    fullMessage.message
  }
  
  // Constants
  static let avatarSize: CGFloat = 28

  // View renderers
  var body: some View {
    HStack(alignment: .top, spacing: 0) {
      avatar.padding(.trailing, 8)
      content
      
      Spacer(minLength: 0)
    }
    .fixedSize(horizontal: false, vertical: true) // Add this line
    .contentShape(Rectangle())
    .contextMenu {
      Button("ID: \(message.id)") {}.disabled(true)
        
      Button("Copy") {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(message.text ?? "", forType: .string)
      }
    }
    .scaleEffect(x: 1, y: -1, anchor: .center)
  }
  
  @ViewBuilder
  var avatar: some View {
    if showsAvatar {
      UserAvatar(user: from, size: Self.avatarSize)
        .frame(width: Self.avatarSize, height: Self.avatarSize)
    } else {
      Color.clear
        .frame(width: Self.avatarSize, height: 1)
    }
  }
  
  @ViewBuilder
  var content: some View {
    VStack(alignment: .leading, spacing: 2) {
      if showsName {
        header
      }
      
      messageContent
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
  
  @ViewBuilder
  var header: some View {
    Text(from.firstName ?? from.username ?? "")
      .font(.body.weight(.medium))
  }
  
  @ViewBuilder
  var messageContent: some View {
    Text(message.text ?? "empty")
      .fixedSize(horizontal: false, vertical: true)
      .textSelection(.enabled)
  }
}

// #Preview {
//  MessageView(fullMessage: FullMessage.preview)
// }
