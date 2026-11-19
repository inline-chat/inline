import Auth
import InlineKit
import InlineUI
import SwiftUI
import UIKit

/// The Members tab: who can read a thread, directly or through a group. You
/// come first, then owners and admins, then everyone by name. Tapping a person
/// opens their info; long-press for Message, bot access and Remove.
struct PeerInfoIOSMembersList: View {
  @ObservedObject var participants: ChatParticipantsWithMembersViewModel
  let roles: [Int64: MemberRole]
  let isPublic: Bool
  let canAdd: Bool
  let canRemove: Bool
  let onAdd: () -> Void
  let onOpen: (UserInfo) -> Void
  let onMessage: (UserInfo) -> Void
  let onManageBot: (UserInfo) -> Void
  let onRemove: (UserInfo) -> Void
  let onRemoveGroup: (UserGroup) -> Void

  @ObservedObject private var grants = AgentGrantStore.shared
  @ObservedObject private var agentStore = AgentWorkStateStore.shared

  private var currentUserId: Int64? { Auth.shared.getCurrentUserId() }

  private var people: [UserInfo] {
    participants.participants.sorted { lhs, rhs in
      let lhsRank = rank(lhs), rhsRank = rank(rhs)
      if lhsRank != rhsRank { return lhsRank < rhsRank }
      let comparison = lhs.user.displayName.localizedCaseInsensitiveCompare(rhs.user.displayName)
      return comparison == .orderedSame ? lhs.user.id < rhs.user.id : comparison == .orderedAscending
    }
  }

  private func rank(_ info: UserInfo) -> Int {
    if info.user.id == currentUserId { return 0 }
    switch roles[info.user.id] {
    case .owner: return 1
    case .admin: return 2
    default: return info.user.bot ? 4 : 3
    }
  }

  private var groups: [UserGroup] {
    participants.groupParticipants.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
  }

  var body: some View {
    VStack(spacing: 18) {
      if isPublic {
        PeerInfoIOSCard {
          HStack(spacing: 12) {
            PeerInfoIOSRowIcon(systemImage: "globe")
            Text("Everyone in this space can read and join")
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          .padding(.horizontal, 16)
          .padding(.vertical, 10)
        }
      }

      if !groups.isEmpty {
        PeerInfoIOSCard(groups.count == 1 ? "1 Group" : "\(groups.count) Groups") {
          ForEach(groups) { group in
            groupRow(group)
          }
        }
      }

      PeerInfoIOSCard(people.count == 1 ? "1 Person" : "\(people.count) People") {
        if canAdd {
          Button(action: onAdd) {
            HStack(spacing: 12) {
              Image(systemName: "person.badge.plus")
                .font(.system(size: 17, weight: .medium))
                .frame(width: 36, height: 36)
              Text("Add Members")
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .foregroundStyle(.tint)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
          }
          .buttonStyle(PeerInfoIOSRowButtonStyle())
        }
        ForEach(people, id: \.id) { person in
          personRow(person)
        }
      }
    }
    .padding(.horizontal, 16)
  }

  private func personRow(_ person: UserInfo) -> some View {
    let isMe = person.user.id == currentUserId
    let removable = canRemove && !isMe
    return Button {
      onOpen(person)
    } label: {
      HStack(spacing: 12) {
        UserAvatar(userInfo: person, size: 36)
          .overlay(alignment: .bottomTrailing) { botDot(person) }
        VStack(alignment: .leading, spacing: 1) {
          HStack(spacing: 5) {
            Text(person.user.displayName).lineLimit(1)
            if isMe {
              Text("You").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            }
          }
          if let detail = detail(person) {
            Text(detail).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        if let role = roles[person.user.id], role != .member {
          Text(role == .owner ? "owner" : "admin")
            .font(.caption.weight(.semibold))
            .foregroundStyle(role == .owner ? Color.purple : Color.green)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background((role == .owner ? Color.purple : Color.green).opacity(0.14), in: Capsule())
        }
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 8)
      .contentShape(Rectangle())
    }
    .buttonStyle(PeerInfoIOSRowButtonStyle())
    .accessibilityHint("Shows their info")
    .contextMenu {
      if !isMe {
        Button("Message", systemImage: "message") { onMessage(person) }
      }
      Button("Show Info", systemImage: "info.circle") { onOpen(person) }
      if person.user.bot, grants.ownedGrants(botUserID: person.user.id) != nil {
        Button("Manage Bot Access", systemImage: "person.2.badge.gearshape") { onManageBot(person) }
      }
      if removable {
        Divider()
        Button("Remove from Thread", systemImage: "person.badge.minus", role: .destructive) { onRemove(person) }
      }
    }
    .task(id: person.user.id) {
      if person.user.bot { grants.ensureLoaded(botUserID: person.user.id) }
    }
  }

  private func groupRow(_ group: UserGroup) -> some View {
    HStack(spacing: 12) {
      PeerInfoIOSRowIcon(systemImage: "person.3.fill")
        .frame(width: 36)
      VStack(alignment: .leading, spacing: 1) {
        Text(group.name).lineLimit(1)
        Text(group.memberCount == 1 ? "1 person" : "\(group.memberCount) people")
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 8)
    .contentShape(Rectangle())
    .contextMenu {
      if canRemove {
        Button("Remove Group Access", systemImage: "minus.circle", role: .destructive) { onRemoveGroup(group) }
      }
    }
    .accessibilityElement(children: .combine)
  }

  /// Bots show whether they can answer; people's presence stays private.
  private func detail(_ person: UserInfo) -> String? {
    if person.user.bot {
      return BotStatusSummary.make(user: person.user, runtime: agentStore.runtimeInfo(botUserID: person.user.id))?.title ?? "bot"
    }
    guard let username = person.user.username, !username.isEmpty else { return nil }
    return "@\(username)"
  }

  @ViewBuilder
  private func botDot(_ person: UserInfo) -> some View {
    if person.user.bot,
       let status = BotStatusSummary.make(user: person.user, runtime: agentStore.runtimeInfo(botUserID: person.user.id))
    {
      Circle()
        .fill(status.tone.tint)
        .frame(width: 11, height: 11)
        .overlay(Circle().stroke(Color(uiColor: .secondarySystemGroupedBackground), lineWidth: 2))
        .accessibilityHidden(true)
    }
  }
}

/// The Threads tab: subthreads of a thread, or threads shared with a person
/// or bot. Tapping opens the thread; long-press for its info and link.
struct PeerInfoIOSThreadsList: View {
  let model: PeerInfoThreadsModel
  let emptyMessage: String
  let onOpen: (PeerInfoThreadsModel.Item) -> Void
  let onShowInfo: (PeerInfoThreadsModel.Item) -> Void

  var body: some View {
    VStack(spacing: 12) {
      if !model.items.isEmpty {
        PeerInfoIOSCard {
          ForEach(model.items) { item in
            row(item)
              .onAppear {
                if item.id == model.items.last?.id { model.loadMore() }
              }
          }
        }
      }
      footer
    }
    .padding(.horizontal, 16)
  }

  private func row(_ item: PeerInfoThreadsModel.Item) -> some View {
    PeerInfoIOSNavigationRow(
      title: item.chat.humanReadableTitle ?? "Untitled",
      detail: detail(item),
      action: { onOpen(item) },
      leading: {
        ThreadIconView(ThreadIconDescriptor(chat: item.chat), size: .large(36), shape: .circle)
      },
      trailing: {
        if item.unreadCount > 0 {
          Text(item.unreadCount, format: .number)
            .font(.caption.weight(.semibold).monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Color.accentColor, in: Capsule())
            .accessibilityLabel("\(item.unreadCount) unread")
        }
      }
    )
    .contextMenu {
      Button("Open Thread", systemImage: "bubble.left.and.bubble.right") { onOpen(item) }
      Button("Show Info", systemImage: "info.circle") { onShowInfo(item) }
    }
  }

  private func detail(_ item: PeerInfoThreadsModel.Item) -> String {
    let date = item.activityDate.formatted(.relative(presentation: .named))
    guard let space = item.space?.displayName else { return date }
    return "\(space) · \(date)"
  }

  @ViewBuilder
  private var footer: some View {
    switch model.loadState {
    case .loading where model.items.isEmpty, .idle where model.items.isEmpty:
      ProgressView().frame(maxWidth: .infinity).padding(.vertical, 28)
    case .loading:
      ProgressView().frame(maxWidth: .infinity)
    case .failed:
      PeerInfoIOSEmptyState(systemImage: "exclamationmark.triangle", message: "Couldn’t load threads.", actionTitle: "Try Again", action: model.retry)
    case .unsupported where model.items.isEmpty:
      PeerInfoIOSEmptyState(systemImage: "bubble.left.and.bubble.right", message: "Shared threads need a newer server.")
    case .loaded where model.items.isEmpty:
      PeerInfoIOSEmptyState(systemImage: "bubble.left.and.bubble.right", message: emptyMessage)
    default:
      EmptyView()
    }
  }
}

/// A calm empty or error state: a symbol, one line, and an optional action.
struct PeerInfoIOSEmptyState: View {
  let systemImage: String
  let message: String
  var actionTitle: String? = nil
  var action: (() -> Void)? = nil

  var body: some View {
    VStack(spacing: 10) {
      Image(systemName: systemImage)
        .font(.system(size: 28))
        .foregroundStyle(.tertiary)
      Text(message)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
      if let actionTitle, let action {
        Button(actionTitle, action: action)
          .buttonStyle(.bordered)
      }
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 36)
    .padding(.horizontal, 24)
  }
}
