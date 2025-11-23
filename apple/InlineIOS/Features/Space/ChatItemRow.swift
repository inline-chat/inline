import InlineKit
import InlineUI
import SwiftUI

struct ChatItemRow: View {
  let item: SpaceChatItem
  @Environment(Router.self) private var router
  @EnvironmentObject private var data: DataManager
  @Environment(\.colorScheme) private var colorScheme
  
  var hasUnread: Bool {
    (item.dialog.unreadCount ?? 0) > 0 || (item.dialog.unreadMark == true)
  }
  
  private var unreadCount: Int {
    Int(item.dialog.unreadCount ?? 0)
  }
  
  private var chatProfileColors: [Color] {
    let _ = colorScheme
    return [
      Color(.systemGray3).adjustLuminosity(by: 0.2),
      Color(.systemGray5).adjustLuminosity(by: 0),
    ]
  }
  
  private var chatTitle: String {
    item.title ?? "Chat"
  }
  
  private var senderDisplayName: String? {
    if let sender = item.from?.user {
      sender.displayName
    } else if let user = item.user {
      user.displayName
    } else {
      nil
    }
  }
  
  private var lastMessageIcon: String? {
    guard let message = item.message else { return nil }
    if message.photoId != nil || message.videoId != nil {
      return "photo"
    }
    if message.documentId != nil {
      return "doc.text"
    }
    if message.isSticker == true {
      return "face.smiling"
    }
    return nil
  }
  
  private var lastMessagePreview: String {
    guard let message = item.message else {
      return "No messages yet"
    }
    
    if let text = message.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
      return text.replacingOccurrences(of: "\n", with: " ")
    }
    
    if lastMessageIcon != nil {
      return "Attachment"
    }
    
    return "No messages yet"
  }
  
  var body: some View {
    Button {
      router.push(.chat(peer: item.peerId))
    } label: {
      HStack(alignment: .top, spacing: 12) {
        Circle()
          .fill(
            LinearGradient(
              colors: chatProfileColors,
              startPoint: .topLeading,
              endPoint: .bottomTrailing
            )
          )
          .frame(width: 56, height: 56)
          .overlay {
            Group {
              if let emoji = item.chat?.emoji, !emoji.isEmpty {
                Text(emoji)
                  .font(.title3)
              } else {
                Image(systemName: "message.fill")
                  .font(.title)
                  .foregroundColor(.secondary)
              }
            }
          }
        
        VStack(alignment: .leading, spacing: 0) {
          HStack(alignment: .center, spacing: 0) {
            Text(chatTitle)
              .font(.body.weight(.medium))
              .foregroundColor(.primary)
              .lineLimit(1)
            Spacer()
            if hasUnread {
              Text("\(unreadCount)")
                .font(.subheadline)
                .foregroundColor(.white)
                .contentTransition(.numericText())
                .animation(.spring(duration: 0.35), value: unreadCount)
                .padding(.horizontal, 6)
                .background(
                  Capsule()
                    .fill(Color(.systemGray))
                    .frame(minWidth: 22)
                  
                )
            }
          }
          
          if let senderDisplayName {
            Text(senderDisplayName)
              .font(.body)
              .foregroundColor(.primary)
              .lineLimit(1)
          }
          
          HStack(alignment: .firstTextBaseline, spacing: 4) {
            if let icon = lastMessageIcon {
              Image(systemName: icon)
                .font(.subheadline)
                .foregroundColor(.secondary)
            }
            Text(lastMessagePreview)
              .font(.body)
              .foregroundColor(.secondary)
              .lineLimit(1)
              .truncationMode(.tail)
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
      Button(role: .destructive) {
        Task {
          try await data.updateDialog(
            peerId: item.peerId,
            archived: true
          )
        }
      } label: {
        Image(systemName: "tray.and.arrow.down.fill")
      }
      .tint(Color(.systemGray2))
      
      Button {
        Task {
          try await data.updateDialog(
            peerId: item.peerId,
            pinned: !(item.dialog.pinned ?? false)
          )
        }
      } label: {
        Image(systemName: item.dialog.pinned ?? false ? "pin.slash.fill" : "pin.fill")
      }
      .tint(.indigo)
    }
  }
}
