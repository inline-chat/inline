import Auth
import InlineKit
import InlineUI
import Logger
import SwiftUI

/// A small title above a chat info card.
struct ChatInfoSectionTitle: View {
  let title: String

  init(_ title: String) {
    self.title = title
  }

  var body: some View {
    Text(title)
      .font(.subheadline.weight(.semibold))
      .foregroundStyle(.secondary)
      .padding(.horizontal, 4)
  }
}

extension BotStatusSummary.Tone {
  var color: Color {
    switch self {
    case .online: Color(nsColor: .systemGreen)
    case .offline: Color(nsColor: .systemGray)
    case .attention: Color(nsColor: .systemOrange)
    }
  }
}

/// "● Online" under a bot's name in its chat info header.
struct BotChatInfoStatusLine: View {
  let user: User
  @ObservedObject private var store = AgentWorkStateStore.shared

  var body: some View {
    if let status = BotStatusSummary.make(user: user, runtime: store.runtimeInfo(botUserID: user.id)) {
      HStack(spacing: 5) {
        Circle()
          .fill(status.tone.color)
          .frame(width: 7, height: 7)
        Text(status.title)
      }
      .font(.callout)
      .foregroundStyle(.secondary)
      .accessibilityElement(children: .combine)
    }
  }
}

/// How a bot is doing: status, the machine it runs on and what it runs.
/// Renders from the cached runtime; the chat info's loads refresh it.
struct BotChatInfoStatusSection: View {
  let user: User
  @ObservedObject private var store = AgentWorkStateStore.shared

  private var runtime: AgentRuntimeInfo? { store.runtimeInfo(botUserID: user.id) }

  var body: some View {
    let status = BotStatusSummary.make(user: user, runtime: runtime)
    if status != nil || runtime?.machineLabel != nil || runtime?.runtimeTitle != nil {
      VStack(alignment: .leading, spacing: 6) {
        ChatInfoSectionTitle("Status")
        GroupBox {
          VStack(alignment: .leading, spacing: 0) {
            if let status {
              ChatInfoRow("Status") {
                VStack(alignment: .trailing, spacing: 2) {
                  HStack(spacing: 6) {
                    Circle()
                      .fill(status.tone.color)
                      .frame(width: 8, height: 8)
                    Text(status.title)
                  }
                  if let detail = status.detail {
                    Text(detail)
                      .font(.caption)
                      .foregroundStyle(status.tone == .attention ? Color.orange : Color.secondary)
                      .multilineTextAlignment(.trailing)
                  }
                }
              }
            }
            valueRow("Machine", runtime?.machineLabel)
            valueRow("Runtime", runtime?.runtimeTitle)
            valueRow("Inline CLI", runtime?.bridgeVersion)
          }
          .padding(.vertical, 4)
          .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
    }
  }

  @ViewBuilder
  private func valueRow(_ title: String, _ value: String?) -> some View {
    if let value {
      Divider()
      ChatInfoRow(title) {
        Text(value)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
          .textSelection(.enabled)
      }
    }
  }
}

/// Who may use a bot: for its owner, the people it is shared with and a way to
/// change that; for others, its owner and what they may do with it.
struct BotChatInfoAccessSection: View {
  let bot: UserInfo
  @ObservedObject private var grants = AgentGrantStore.shared
  @State private var showsAccessSheet = false
  @State private var loadedUsersGeneration = 0

  private var botUserID: Int64 { bot.user.id }

  var body: some View {
    Group {
      if let owned = grants.ownedGrants(botUserID: botUserID) {
        VStack(alignment: .leading, spacing: 6) {
          ChatInfoSectionTitle("Access")
          GroupBox {
            ChatInfoRow("Shared With") {
              HStack(spacing: 10) {
                avatarStack(Array(owned.userIDs.sorted().prefix(3)))
                Text(sharedSummary(owned.userIDs.count))
                  .foregroundStyle(.secondary)
                Button("Manage…") { showsAccessSheet = true }
              }
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
          }
          Text("People with access can start and steer \(bot.user.shortDisplayName) in chats they share with it. You always have access.")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
        }
      } else if let access = grants.access(botUserID: botUserID), !access.isOwner {
        VStack(alignment: .leading, spacing: 6) {
          ChatInfoSectionTitle("Access")
          GroupBox {
            VStack(alignment: .leading, spacing: 0) {
              ChatInfoRow("Owner") {
                HStack(spacing: 6) {
                  if let owner = cachedUser(access.ownerUserID) {
                    UserAvatar(user: owner.user, size: 18)
                  }
                  Text(cachedUser(access.ownerUserID)?.user.displayName ?? "Someone else")
                    .foregroundStyle(.secondary)
                }
              }
              Divider()
              ChatInfoRow("Your Access") {
                Text(access.viewerAccessSummary)
                  .foregroundStyle(.secondary)
              }
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
          }
        }
      }
    }
    .task(id: botUserID) {
      grants.ensureLoaded(botUserID: botUserID)
    }
    .task(id: peopleToLoad) {
      let missing = peopleToLoad.filter { ObjectCache.shared.getCachedUser(id: $0) == nil }
      guard !missing.isEmpty else { return }
      await ObjectCache.shared.ensure(missing.map { .user($0) })
      loadedUsersGeneration &+= 1
    }
    .sheet(isPresented: $showsAccessSheet) {
      BotAccessSheet(bot: bot)
    }
  }

  private var peopleToLoad: [Int64] {
    if let owned = grants.ownedGrants(botUserID: botUserID) {
      return Array(owned.userIDs.sorted().prefix(3))
    }
    if let access = grants.access(botUserID: botUserID), !access.isOwner, access.ownerUserID > 0 {
      return [access.ownerUserID]
    }
    return []
  }

  private func avatarStack(_ userIDs: [Int64]) -> some View {
    HStack(spacing: -6) {
      ForEach(userIDs, id: \.self) { userID in
        Group {
          if let userInfo = cachedUser(userID) {
            UserAvatar(user: userInfo.user, size: 20)
          } else {
            Circle().fill(Color.secondary.opacity(0.3))
          }
        }
        .frame(width: 20, height: 20)
        .overlay(Circle().stroke(Color(nsColor: .controlBackgroundColor), lineWidth: 1.5))
      }
    }
    .accessibilityHidden(true)
  }

  private func sharedSummary(_ count: Int) -> String {
    switch count {
    case 0: String(localized: "Only you")
    case 1: String(localized: "1 person")
    default: String(localized: "\(count) people")
    }
  }

  private func cachedUser(_ userID: Int64) -> UserInfo? {
    _ = loadedUsersGeneration
    return ObjectCache.shared.getCachedUser(id: userID)
  }
}

/// Adds and removes the people who may use a bot the viewer owns.
struct BotAccessSheet: View {
  let bot: UserInfo

  @Environment(\.realtimeV2) private var realtimeV2
  @Environment(\.dismiss) private var dismiss
  @ObservedObject private var grants = AgentGrantStore.shared
  @State private var search: BotAccessPeopleSearch?
  @State private var pending: Set<Int64> = []
  @State private var errorMessage: String?
  @State private var loadedUsersGeneration = 0

  private let log = Log.scoped("BotAccessSheet")

  private var botUserID: Int64 { bot.user.id }
  private var grantedUserIDs: [Int64] {
    (grants.ownedGrants(botUserID: botUserID)?.userIDs ?? []).sorted {
      name($0).localizedCaseInsensitiveCompare(name($1)) == .orderedAscending
    }
  }

  private var isSearching: Bool {
    !(search?.query.trimmingCharacters(in: .whitespaces).isEmpty ?? true)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 4) {
        Text("Shared With")
          .font(.title3.weight(.semibold))
        Text("People with access can start and steer \(bot.user.shortDisplayName) in chats they share with it.")
          .font(.callout)
          .foregroundStyle(.secondary)
      }
      .padding([.horizontal, .top], 20)
      .padding(.bottom, 12)

      TextField(
        "Add people by name or username",
        text: Binding(get: { search?.query ?? "" }, set: { search?.query = $0 })
      )
      .textFieldStyle(.roundedBorder)
      .padding(.horizontal, 20)
      .padding(.bottom, 8)

      if let errorMessage {
        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
          .font(.callout)
          .foregroundStyle(.red)
          .padding(.horizontal, 20)
          .padding(.bottom, 8)
      }

      List {
        if isSearching, let search {
          Section("Results") {
            if search.results.isEmpty {
              Text(search.isSearching ? "Searching…" : "No people found.")
                .foregroundStyle(.secondary)
            }
            ForEach(search.results) { person in
              personRow(person) {
                if grants.ownedGrants(botUserID: botUserID)?.hasGrant(userID: person.user.id) == true {
                  Label("Added", systemImage: "checkmark")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.secondary)
                } else {
                  Button("Add") { setAccess(true, userID: person.user.id, name: person.user.shortDisplayName) }
                    .disabled(pending.contains(person.user.id))
                }
              }
            }
          }
        }

        Section("People With Access") {
          if let viewerID = Auth.shared.getCurrentUserId(), let viewer = cachedUser(viewerID) {
            personRow(viewer) {
              Text("Owner").foregroundStyle(.secondary)
            }
          }
          if grantedUserIDs.isEmpty {
            Text("Only you so far. Search above to add people.")
              .foregroundStyle(.secondary)
          }
          ForEach(grantedUserIDs, id: \.self) { userID in
            if let person = cachedUser(userID) {
              personRow(person) {
                Button("Remove", role: .destructive) {
                  setAccess(false, userID: userID, name: person.user.shortDisplayName)
                }
                .disabled(pending.contains(userID))
              }
            } else {
              Text("Loading…").foregroundStyle(.secondary)
            }
          }
        }
      }
      .listStyle(.inset)
      .frame(minHeight: 260)

      HStack {
        Spacer()
        Button("Done") { dismiss() }
          .keyboardShortcut(.defaultAction)
      }
      .padding(16)
    }
    .frame(width: 440, height: 520)
    .onAppear {
      if search == nil { search = BotAccessPeopleSearch(botUserID: botUserID, realtime: realtimeV2) }
      grants.refresh(botUserID: botUserID)
    }
    .onDisappear { search?.cancel() }
    .task(id: grantedUserIDs) {
      let ids = grantedUserIDs + [Auth.shared.getCurrentUserId()].compactMap(\.self)
      let missing = ids.filter { ObjectCache.shared.getCachedUser(id: $0) == nil }
      guard !missing.isEmpty else { return }
      await ObjectCache.shared.ensure(missing.map { .user($0) })
      loadedUsersGeneration &+= 1
    }
  }

  private func personRow(_ person: UserInfo, @ViewBuilder trailing: () -> some View) -> some View {
    HStack(spacing: 10) {
      UserAvatar(user: person.user, size: 28)
      VStack(alignment: .leading, spacing: 1) {
        Text(person.user.displayName)
          .lineLimit(1)
        if let username = person.user.username, !username.isEmpty {
          Text("@\(username)")
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      trailing()
    }
    .padding(.vertical, 2)
  }

  private func cachedUser(_ userID: Int64) -> UserInfo? {
    _ = loadedUsersGeneration
    return ObjectCache.shared.getCachedUser(id: userID)
  }

  private func name(_ userID: Int64) -> String {
    ObjectCache.shared.getCachedUser(id: userID)?.user.displayName ?? ""
  }

  private func setAccess(_ hasAccess: Bool, userID: Int64, name: String) {
    guard !pending.contains(userID) else { return }
    pending.insert(userID)
    errorMessage = nil
    Task { @MainActor in
      defer { pending.remove(userID) }
      do {
        if hasAccess {
          try await grants.setGrant(botUserID: botUserID, userID: userID)
        } else {
          try await grants.deleteGrant(botUserID: botUserID, userID: userID)
        }
      } catch {
        log.error("Failed to update access for user \(userID) on bot \(botUserID)", error: error)
        errorMessage = hasAccess
          ? String(localized: "Couldn’t give \(name) access. Try again.")
          : String(localized: "Couldn’t remove \(name)’s access. Try again.")
      }
    }
  }
}
