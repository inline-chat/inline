import InlineKit
import InlineUI
import SwiftUI

struct MessageView: View {
  // Props
  var fullMessage: FullMessage
  var showsAvatar: Bool = true
  var showsName: Bool = true
  
  // Computed
  var from: User {
    fullMessage.user ?? User.deletedInstance
  }

  var message: Message {
    fullMessage.message
  }
  
  // Constants
  static let avatarSize: CGFloat = 32

  // View renderers
  var body: some View {
    HStack(alignment: .top, spacing: 0) {
      avatar
      content
      
      Spacer(minLength: 0)
    }
    .fixedSize(horizontal: false, vertical: true) // Add this line
  }
  
  @ViewBuilder
  var avatar: some View {
    if showsAvatar {
      UserAvatar(user: from, size: Self.avatarSize)
        .frame(width: Self.avatarSize, height: Self.avatarSize)
    } else {
      EmptyView()
        .frame(width: Self.avatarSize, height: Self.avatarSize)
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
  }
  
  @ViewBuilder
  var messageContent: some View {
    Text(message.text ?? "empty")
      .fixedSize(horizontal: false, vertical: true)
  }
}
