import InlineSharedSnapshot
import SwiftUI
import WidgetKit

/// The top of the chat list on the home and lock screens. The app writes the snapshot and reloads
/// the timeline when it changes; the widget never opens the database or the network.
struct ChatsWidget: Widget {
  var body: some WidgetConfiguration {
    StaticConfiguration(kind: WidgetChatsSnapshot.widgetKind, provider: ChatsProvider()) { entry in
      ChatsWidgetView(entry: entry)
    }
    .configurationDisplayName("Chats")
    .description("Your latest Inline conversations.")
    .supportedFamilies([
      .systemSmall,
      .systemMedium,
      .systemLarge,
      .accessoryCircular,
      .accessoryRectangular,
      .accessoryInline,
    ])
  }
}

struct ChatsEntry: TimelineEntry {
  enum Content {
    case chats(WidgetChatsSnapshot)
    case signedOut
    /// No snapshot for the signed-in account yet.
    case openApp
  }

  let date: Date
  let content: Content
}

struct ChatsProvider: TimelineProvider {
  func placeholder(in _: Context) -> ChatsEntry {
    ChatsEntry(date: Date(), content: .chats(.preview))
  }

  func getSnapshot(in context: Context, completion: @escaping (ChatsEntry) -> Void) {
    let entry = currentEntry()
    // The widget gallery shows sample chats until the app has written real ones.
    if context.isPreview, case .chats = entry.content {
      completion(entry)
      return
    }
    completion(context.isPreview ? placeholder(in: context) : entry)
  }

  func getTimeline(in _: Context, completion: @escaping (Timeline<ChatsEntry>) -> Void) {
    // The app reloads on change. The midnight entry only updates "today" times to weekdays.
    let entry = currentEntry()
    let midnight = Calendar.current.startOfDay(for: Date()).addingTimeInterval(24 * 60 * 60 + 60)
    completion(Timeline(entries: [entry], policy: .after(midnight)))
  }

  private func currentEntry() -> ChatsEntry {
    guard let store = SharedSnapshotStore.appGroup() else {
      return ChatsEntry(date: Date(), content: .openApp)
    }
    let content: ChatsEntry.Content = switch store.read(WidgetChatsSnapshot.self) {
    case let .current(snapshot), let .unverified(snapshot):
      .chats(snapshot.payload)
    case .signedOut:
      .signedOut
    case .missing, .otherOwner, .incompatible:
      .openApp
    }
    return ChatsEntry(date: Date(), content: content)
  }
}

// MARK: - Views

struct ChatsWidgetView: View {
  @Environment(\.widgetFamily) private var family
  let entry: ChatsEntry

  var body: some View {
    content
      .containerBackground(.background, for: .widget)
  }

  @ViewBuilder
  private var content: some View {
    switch entry.content {
    case let .chats(snapshot) where !snapshot.chats.isEmpty:
      chats(snapshot)
    case .chats:
      message("No chats yet", systemImage: "bubble.left.and.bubble.right")
    case .signedOut:
      message("Sign in to Inline", systemImage: "person.crop.circle")
    case .openApp:
      message("Open Inline to see your chats", systemImage: "bubble.left.and.bubble.right")
    }
  }

  @ViewBuilder
  private func chats(_ snapshot: WidgetChatsSnapshot) -> some View {
    switch family {
    case .systemSmall:
      SmallChatView(chat: snapshot.chats[0])
        .widgetURL(snapshot.chats[0].deepLinkURL)
    case .systemMedium:
      ChatListView(chats: snapshot.chats, capacity: 3, avatarSize: 34)
    case .systemLarge:
      ChatListView(chats: snapshot.chats, capacity: 6, avatarSize: 40)
    case .accessoryCircular:
      UnreadCircleView(count: snapshot.unreadChatCount)
        .widgetURL(snapshot.chats.first(where: \.isUnread)?.deepLinkURL)
    case .accessoryRectangular:
      let chat = snapshot.chats.first(where: \.isUnread) ?? snapshot.chats[0]
      RectangularChatView(chat: chat)
        .widgetURL(chat.deepLinkURL)
    case .accessoryInline:
      Text(snapshot.unreadChatCount == 0 ? "No unread chats" : "\(snapshot.unreadChatCount) unread")
    default:
      ChatListView(chats: snapshot.chats, capacity: 3, avatarSize: 34)
    }
  }

  @ViewBuilder
  private func message(_ text: String, systemImage: String) -> some View {
    switch family {
    case .accessoryInline:
      Text(text)
    case .accessoryCircular:
      ZStack {
        AccessoryWidgetBackground()
        Image(systemName: systemImage)
      }
    default:
      VStack(spacing: 8) {
        Image(systemName: systemImage)
          .font(.title2)
          .foregroundStyle(.secondary)
        Text(text)
          .font(.footnote)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }
}

private struct SmallChatView: View {
  let chat: WidgetChat

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(alignment: .top) {
        ChatAvatarView(chat: chat, size: 44)
        Spacer(minLength: 0)
        UnreadBadge(chat: chat)
      }
      Spacer(minLength: 0)
      Text(chat.title)
        .font(.subheadline.weight(chat.isUnread ? .semibold : .medium))
        .lineLimit(1)
      Text(chat.preview)
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(2)
        .privacySensitive()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
  }
}

private struct ChatListView: View {
  let chats: [WidgetChat]
  /// Rows the widget fits. A full list spreads to fill the height; a shorter one stacks at the top.
  let capacity: Int
  let avatarSize: CGFloat

  var body: some View {
    let isFull = chats.count >= capacity
    VStack(alignment: .leading, spacing: isFull ? 0 : 12) {
      ForEach(Array(chats.prefix(capacity).enumerated()), id: \.element.id) { index, chat in
        if isFull, index > 0 { Spacer(minLength: 4) }
        if let url = chat.deepLinkURL {
          Link(destination: url) { ChatRow(chat: chat, avatarSize: avatarSize) }
        } else {
          ChatRow(chat: chat, avatarSize: avatarSize)
        }
      }
      if !isFull { Spacer(minLength: 0) }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }
}

private struct ChatRow: View {
  let chat: WidgetChat
  let avatarSize: CGFloat

  var body: some View {
    HStack(spacing: 10) {
      ChatAvatarView(chat: chat, size: avatarSize)
      VStack(alignment: .leading, spacing: 1) {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          Text(chat.title)
            .font(.subheadline.weight(chat.isUnread ? .semibold : .regular))
            .lineLimit(1)
          Spacer(minLength: 4)
          if let date = chat.date {
            Text(ChatDateFormat.string(for: date))
              .font(.caption2)
              .foregroundStyle(.secondary)
          }
        }
        HStack(spacing: 6) {
          Text(chat.preview.isEmpty ? " " : chat.preview)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .privacySensitive()
          Spacer(minLength: 0)
          UnreadBadge(chat: chat)
        }
      }
    }
  }
}

private struct RectangularChatView: View {
  let chat: WidgetChat

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 4) {
        if chat.isUnread {
          Circle().frame(width: 6, height: 6).widgetAccentable()
        }
        Text(chat.title)
          .font(.headline)
          .lineLimit(1)
          .widgetAccentable()
      }
      Text(chat.preview)
        .font(.caption)
        .lineLimit(2)
        .privacySensitive()
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct UnreadCircleView: View {
  let count: Int

  var body: some View {
    ZStack {
      AccessoryWidgetBackground()
      VStack(spacing: 0) {
        Image(systemName: count > 0 ? "bubble.left.fill" : "bubble.left")
          .font(.caption)
          .widgetAccentable()
        Text(count > 99 ? "99+" : "\(count)")
          .font(.headline.monospacedDigit())
          .minimumScaleFactor(0.6)
      }
    }
  }
}

private struct UnreadBadge: View {
  let chat: WidgetChat

  var body: some View {
    if chat.unreadCount > 0 {
      Text(chat.unreadCount > 99 ? "99+" : "\(chat.unreadCount)")
        .font(.caption2.weight(.semibold).monospacedDigit())
        .foregroundStyle(.white)
        .padding(.horizontal, 6)
        .frame(minWidth: 18, minHeight: 18)
        .background(Capsule().fill(Color.accentColor))
    } else if chat.isUnread {
      Circle()
        .fill(Color.accentColor)
        .frame(width: 10, height: 10)
    }
  }
}

private struct ChatAvatarView: View {
  let chat: WidgetChat
  let size: CGFloat

  var body: some View {
    Group {
      if let image = WidgetAvatarImage.load(chat.avatarURL, pointSize: size) {
        Image(uiImage: image)
          .resizable()
          .scaledToFill()
      } else {
        ZStack {
          Rectangle().fill(tint.gradient)
          if let emoji = chat.emoji, !emoji.isEmpty {
            Text(emoji).font(.system(size: size * 0.5))
          } else {
            Text(chat.initials)
              .font(.system(size: size * 0.4, weight: .semibold, design: .rounded))
              .foregroundStyle(.white)
          }
        }
      }
    }
    .frame(width: size, height: size)
    .clipShape(shape)
  }

  private var shape: AnyShape {
    switch chat.kind {
    case .user: AnyShape(Circle())
    case .thread: AnyShape(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
    }
  }

  private var tint: Color {
    let palette: [Color] = [.blue, .indigo, .purple, .pink, .orange, .teal, .green, .cyan]
    return palette[Int(UInt64(bitPattern: chat.id) % UInt64(palette.count))]
  }
}

enum ChatDateFormat {
  static func string(for date: Date, now: Date = Date()) -> String {
    let calendar = Calendar.current
    if calendar.isDate(date, inSameDayAs: now) {
      return date.formatted(date: .omitted, time: .shortened)
    }
    if let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day,
       days < 7
    {
      return date.formatted(.dateTime.weekday(.abbreviated))
    }
    return date.formatted(.dateTime.month(.abbreviated).day())
  }
}

// MARK: - Sample data

extension WidgetChatsSnapshot {
  static let preview = WidgetChatsSnapshot(
    chats: [
      WidgetChat(
        id: 1, kind: .thread, title: "Design", preview: "Sara: New sidebar mockups are up",
        date: Date().addingTimeInterval(-300), unreadCount: 3, isUnread: true, isPinned: true,
        emoji: "🎨", initials: "D", avatarPath: nil, deepLink: nil
      ),
      WidgetChat(
        id: 2, kind: .user, title: "Alex Kim", preview: "Sounds good, shipping after lunch",
        date: Date().addingTimeInterval(-3_600), unreadCount: 1, isUnread: true, isPinned: false,
        emoji: nil, initials: "AK", avatarPath: nil, deepLink: nil
      ),
      WidgetChat(
        id: 3, kind: .thread, title: "Release", preview: "Build 842 is on TestFlight",
        date: Date().addingTimeInterval(-7_200), unreadCount: 0, isUnread: false, isPinned: false,
        emoji: "🚀", initials: "R", avatarPath: nil, deepLink: nil
      ),
      WidgetChat(
        id: 4, kind: .user, title: "Jordan Lee", preview: "Thanks!",
        date: Date().addingTimeInterval(-86_400), unreadCount: 0, isUnread: false, isPinned: false,
        emoji: nil, initials: "JL", avatarPath: nil, deepLink: nil
      ),
      WidgetChat(
        id: 5, kind: .thread, title: "Infra", preview: "Deploy finished in 4 minutes",
        date: Date().addingTimeInterval(-2 * 86_400), unreadCount: 0, isUnread: false, isPinned: false,
        emoji: "🛠️", initials: "I", avatarPath: nil, deepLink: nil
      ),
      WidgetChat(
        id: 6, kind: .user, title: "Sam Rivera", preview: "See you at the offsite",
        date: Date().addingTimeInterval(-3 * 86_400), unreadCount: 0, isUnread: false, isPinned: false,
        emoji: nil, initials: "SR", avatarPath: nil, deepLink: nil
      ),
    ],
    unreadChatCount: 2
  )
}
