import InlineKit
import InlineSearch
import InlineUI
import SwiftUI

struct InlineSearchResultsList: View {
  let model: InlineSearchViewModel
  let openChat: (InlineSearchChatResult) -> Void
  let openMessage: (LocalMessageSearchResult) -> Void
  let openGlobalUser: (InlineSearchGlobalUserResult) -> Void

  var body: some View {
    List {
      if model.chats.isEmpty == false {
        InlineSearchSectionHeader(title: "Chats")

        ForEach(model.chats) { result in
          InlineSearchChatRow(result: result) {
            openChat(result)
          }
        }
      }

      if model.messages.isEmpty == false {
        InlineSearchSectionHeader(title: "Messages")

        ForEach(model.messages) { result in
          InlineSearchMessageRow(result: result) {
            openMessage(result)
          }
          .onAppear {
            if result.id == model.messages.last?.id {
              model.loadMoreMessages()
            }
          }
        }

        if model.isLoadingMoreMessages {
          HStack {
            Spacer()
            ProgressView()
            Spacer()
          }
        }
      }

      if model.globalUsers.isEmpty == false {
        InlineSearchSectionHeader(title: "People")

        ForEach(model.globalUsers) { result in
          InlineSearchGlobalUserRow(result: result) {
            openGlobalUser(result)
          }
        }
      }
    }
    .listStyle(.plain)
  }
}

private struct InlineSearchSectionHeader: View {
  let title: LocalizedStringKey

  var body: some View {
    Text(title)
      .font(.subheadline.weight(.semibold))
      .foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, alignment: .leading)
      .accessibilityAddTraits(.isHeader)
      .listRowInsets(.init(
        top: 12,
        leading: Theme.Layout.screenEdgeOpticalInset,
        bottom: 4,
        trailing: Theme.Layout.screenEdgeOpticalInset
      ))
      .listRowSeparator(.hidden)
  }
}

private struct InlineSearchChatRow: View {
  let result: InlineSearchChatResult
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      InlineSearchResultRow(
        title: result.title,
        subtitle: subtitle,
        icon: {
          chatIcon
        }
      )
    }
    .buttonStyle(.plain)
    .listRowInsets(.init(
      top: 4,
      leading: Theme.Layout.screenEdgeOpticalInset,
      bottom: 4,
      trailing: Theme.Layout.screenEdgeOpticalInset
    ))
  }

  @ViewBuilder
  private var chatIcon: some View {
    if let userInfo = result.userInfo {
      UserAvatar(userInfo: userInfo, size: 34)
    } else {
      ThreadIconView(
        threadIconDescriptor(
          chat: result.chat,
          title: result.title
        ),
        size: .regular(34),
        shape: .circle
      )
    }
  }

  private var subtitle: String? {
    if result.preview.isEmpty == false {
      return result.preview
    }
    return result.subtitle
  }
}

private struct InlineSearchMessageRow: View {
  let result: LocalMessageSearchResult
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      InlineSearchResultRow(
        title: result.title,
        subtitle: result.snippet,
        detail: dateTitle,
        icon: {
          messageIcon
        }
      )
    }
    .buttonStyle(.plain)
    .listRowInsets(.init(
      top: 4,
      leading: Theme.Layout.screenEdgeOpticalInset,
      bottom: 4,
      trailing: Theme.Layout.screenEdgeOpticalInset
    ))
  }

  @ViewBuilder
  private var messageIcon: some View {
    if let user = result.peerUser {
      UserAvatar(user: user, size: 34)
    } else {
      ThreadIconView(
        threadIconDescriptor(
          chat: result.chat,
          title: result.title
        ),
        size: .regular(34),
        shape: .circle
      )
    }
  }

  private var dateTitle: String {
    result.message.message.date.formatted(date: .abbreviated, time: .omitted)
  }
}

private func threadIconDescriptor(chat: Chat?, title: String) -> ThreadIconDescriptor {
  if let chat {
    return ThreadIconDescriptor(chat: chat)
  }

  return ThreadIconDescriptor(
    emoji: nil,
    title: title,
    accessibilityLabel: title
  )
}

private struct InlineSearchGlobalUserRow: View {
  let result: InlineSearchGlobalUserResult
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      InlineSearchResultRow(
        title: result.title,
        subtitle: result.subtitle,
        icon: {
          UserAvatar(apiUser: result.user, size: 34)
        }
      )
    }
    .buttonStyle(.plain)
    .listRowInsets(.init(
      top: 4,
      leading: Theme.Layout.screenEdgeOpticalInset,
      bottom: 4,
      trailing: Theme.Layout.screenEdgeOpticalInset
    ))
  }
}

private struct InlineSearchResultRow<Icon: View>: View {
  let title: String
  let subtitle: String?
  var detail: String?
  @ViewBuilder let icon: () -> Icon

  init(
    title: String,
    subtitle: String?,
    detail: String? = nil,
    @ViewBuilder icon: @escaping () -> Icon
  ) {
    self.title = title
    self.subtitle = subtitle
    self.detail = detail
    self.icon = icon
  }

  var body: some View {
    HStack(alignment: .center, spacing: 9) {
      icon()
        .frame(width: 34, height: 34)

      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 8) {
          Text(title)
            .font(.body)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)

          if let detail {
            Text(detail)
              .font(.caption2)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
        }

        if let subtitle, subtitle.isEmpty == false {
          Text(subtitle)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
    }
    .contentShape(Rectangle())
  }
}
