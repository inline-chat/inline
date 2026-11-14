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

/// Who can reach a bot: for its owner, who it is shared with and a way to
/// change that; for others, its owner and what they may do with it.
struct BotChatInfoAccessSection: View {
  let bot: UserInfo
  @ObservedObject private var grants = AgentGrantStore.shared
  @State private var showsAccessSheet = false
  @State private var loadedUsersGeneration = 0
  @State private var spaceNames: [Int64: String] = [:]

  private var botUserID: Int64 { bot.user.id }
  private var isOpen: Bool { grants.openToEveryoneByBotUserID[botUserID] == true }

  var body: some View {
    Group {
      if let owned = grants.ownedGrants(botUserID: botUserID) {
        section {
          ChatInfoRow("Shared With") {
            HStack(spacing: 10) {
              if !isOpen { avatarStack(Array(owned.userIDs.sorted().prefix(3))) }
              Text(owned.sharedWithSummary(
                openToEveryone: isOpen,
                spaceNames: owned.spaceIDs.sorted().compactMap { spaceNames[$0] }
              ))
              .foregroundStyle(.secondary)
              Button("Manage…") { showsAccessSheet = true }
            }
          }
        } footer: {
          Text(isOpen
            ? "Anyone on Inline can message \(bot.user.shortDisplayName) and add it to chats."
            : "Only you and the people you share \(bot.user.shortDisplayName) with can message it, mention it or add it to chats.")
        }
      } else if let access = grants.access(botUserID: botUserID), !access.isOwner {
        section {
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
        } footer: {
          if access.canMessage == false {
            Text("Ask \(cachedUser(access.ownerUserID)?.user.shortDisplayName ?? "its owner") to share \(bot.user.shortDisplayName) with you to message it.")
          }
        }
      } else if grants.failedBotUserIDs.contains(botUserID) {
        section {
          ChatInfoRow("Access") {
            HStack(spacing: 10) {
              Text("Couldn’t load")
                .foregroundStyle(.secondary)
              Button("Try Again") { grants.refresh(botUserID: botUserID) }
            }
          }
        } footer: { EmptyView() }
      } else {
        section {
          ChatInfoRow("Access") {
            ProgressView().controlSize(.small)
          }
        } footer: { EmptyView() }
      }
    }
    .task(id: botUserID) {
      grants.ensureLoaded(botUserID: botUserID)
      let spaces = (try? await AppDatabase.shared.reader.read { db in try Space.fetchAll(db) }) ?? []
      spaceNames = Dictionary(spaces.map { ($0.id, $0.displayName) }, uniquingKeysWith: { first, _ in first })
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

  private func section(
    @ViewBuilder content: () -> some View,
    @ViewBuilder footer: () -> some View
  ) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      ChatInfoSectionTitle("Access")
      GroupBox {
        content()
          .padding(.vertical, 4)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      footer()
        .font(.footnote)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 4)
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

  private func cachedUser(_ userID: Int64) -> UserInfo? {
    _ = loadedUsersGeneration
    return ObjectCache.shared.getCachedUser(id: userID)
  }
}

/// Who can reach a bot the viewer owns: everyone, or the people and spaces
/// the owner picks.
struct BotAccessSheet: View {
  let bot: UserInfo
  /// Replaces the standard explanation, e.g. right after the bot was created.
  var introduction: String?

  @Environment(\.realtimeV2) private var realtimeV2
  @Environment(\.dismiss) private var dismiss
  @ObservedObject private var grants = AgentGrantStore.shared
  @ObservedObject private var work = AgentWorkStateStore.shared
  @State private var search: BotAccessPeopleSearch?
  @State private var model: BotAccessListModel
  @State private var loadedUsersGeneration = 0

  init(bot: UserInfo, introduction: String? = nil) {
    self.bot = bot
    self.introduction = introduction
    _model = State(initialValue: BotAccessListModel(botUserID: bot.user.id))
  }

  private var viewerUserID: Int64? { Auth.shared.getCurrentUserId() }
  private var ownerUserID: Int64? {
    guard let id = grants.access(botUserID: botUserID)?.ownerUserID, id > 0 else { return viewerUserID }
    return id
  }

  private var botUserID: Int64 { bot.user.id }
  private var botName: String { bot.user.shortDisplayName }
  private var owned: OwnedAgentGrants? { grants.ownedGrants(botUserID: botUserID) }
  private var isOpen: Bool { grants.openToEveryoneByBotUserID[botUserID] == true }
  /// A bridge answers only its owner and access list, so opening it would
  /// show people a composer for an agent that refuses them.
  private var offersOpenToEveryone: Bool { !work.runtimeBotUserIDs.contains(botUserID) }

  private var grantedUserIDs: [Int64] {
    (owned?.userIDs ?? []).sorted {
      name($0).localizedCaseInsensitiveCompare(name($1)) == .orderedAscending
    }
  }

  private var query: String { search?.query.trimmingCharacters(in: .whitespaces) ?? "" }
  private var isSearching: Bool { !query.isEmpty }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 4) {
        Text("Who Can Message \(botName)")
          .font(.title3.weight(.semibold))
        Text(introduction ?? "People with access can message \(botName), mention it and add it to chats. Nobody else can find it or write to it.")
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      .padding([.horizontal, .top], 20)
      .padding(.bottom, 12)

      if offersOpenToEveryone {
        Toggle(isOn: Binding(get: { isOpen }, set: { model.setOpenToEveryone($0) })) {
          VStack(alignment: .leading, spacing: 1) {
            Text("Anyone Can Message")
            Text("For bots meant for everyone, like a support or team bot.")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
        .toggleStyle(.switch)
        .disabled(model.isChangingOpen || owned == nil)
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
      }

      TextField(
        "Add people, spaces or groups",
        text: Binding(get: { search?.query ?? "" }, set: { search?.query = $0 })
      )
      .textFieldStyle(.roundedBorder)
      .padding(.horizontal, 20)
      .padding(.bottom, 8)

      if let errorMessage = model.errorMessage {
        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
          .font(.callout)
          .foregroundStyle(.red)
          .padding(.horizontal, 20)
          .padding(.bottom, 8)
      }

      List {
        if isSearching, let search {
          let spaces = model.spaceMatches(query, excluding: owned?.spaceIDs ?? [])
          let groups = model.groupMatches(query, excluding: owned?.groupIDs ?? [])
          Section("Results") {
            if search.results.isEmpty, spaces.isEmpty, groups.isEmpty {
              Text(search.isSearching ? "Searching…" : "No people, spaces or groups found.")
                .foregroundStyle(.secondary)
            }
            ForEach(spaces) { space in
              spaceRow(space) {
                Button("Add") { model.setAccess(true, subject: .space(space.id), name: space.displayName) }
                  .disabled(model.pending.contains(.space(space.id)))
              }
            }
            ForEach(groups) { group in
              let title = model.groupTitle(group.id)
              subjectRow(title: title, detail: "Everyone in this group", systemImage: "person.3", space: nil) {
                Button("Add") { model.setAccess(true, subject: .group(group.id), name: title) }
                  .disabled(model.pending.contains(.group(group.id)))
              }
            }
            ForEach(search.results) { person in
              personRow(person) {
                if owned?.hasGrant(userID: person.user.id) == true {
                  Label("Added", systemImage: "checkmark")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.secondary)
                } else {
                  Button("Add") {
                    model.setAccess(true, subject: .user(person.user.id), name: person.user.shortDisplayName)
                  }
                  .disabled(model.pending.contains(.user(person.user.id)))
                }
              }
            }
          }
        }

        Section("Shared With") {
          if let ownerUserID, let owner = cachedUser(ownerUserID) {
            personRow(owner) {
              Text("Owner").foregroundStyle(.secondary)
            }
          }
          if let owned {
            ForEach(owned.spaceIDs.sorted(), id: \.self) { spaceID in
              let title = model.space(spaceID)?.displayName ?? String(localized: "A space")
              subjectRow(title: title, detail: "Everyone in this space", systemImage: "building.2", space: model.space(spaceID)) {
                removeButton(.space(spaceID), name: title)
              }
            }
            ForEach(owned.groupIDs.sorted(), id: \.self) { groupID in
              let title = model.groupTitle(groupID)
              subjectRow(title: title, detail: "Everyone in this group", systemImage: "person.3", space: nil) {
                removeButton(.group(groupID), name: title)
              }
            }
            ForEach(grantedUserIDs, id: \.self) { userID in
              if let person = cachedUser(userID) {
                personRow(person) {
                  rolePicker(userID: userID, name: person.user.shortDisplayName, owned: owned)
                  removeButton(.user(userID), name: person.user.shortDisplayName)
                }
              } else {
                Text("Loading…").foregroundStyle(.secondary)
              }
            }
            if owned.operationsBySubject.isEmpty, !isOpen {
              Text("Only you so far. Search above to add people or a space.")
                .foregroundStyle(.secondary)
            }
            if !owned.adminUserIDs.isEmpty {
              Text("Admins manage \(botName) with its owner: who can message it, its profile, settings and token. Only the owner can delete it.")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          } else if grants.failedBotUserIDs.contains(botUserID) {
            HStack {
              Text("Couldn’t load who has access.")
                .foregroundStyle(.secondary)
              Spacer()
              Button("Try Again") { grants.refresh(botUserID: botUserID) }
            }
          } else {
            HStack(spacing: 8) {
              ProgressView().controlSize(.small)
              Text("Loading access…").foregroundStyle(.secondary)
            }
          }
        }
      }
      .listStyle(.inset)
      .frame(minHeight: 240)

      HStack {
        Spacer()
        Button("Done") { dismiss() }
          .keyboardShortcut(.defaultAction)
      }
      .padding(16)
    }
    .frame(width: 460, height: 580)
    .onAppear {
      if search == nil { search = BotAccessPeopleSearch(botUserID: botUserID, realtime: realtimeV2) }
    }
    .onDisappear { search?.cancel() }
    .task(id: botUserID) { await model.load() }
    .task(id: grantedUserIDs + [ownerUserID ?? 0]) {
      let ids = grantedUserIDs + [ownerUserID].compactMap(\.self)
      let missing = ids.filter { ObjectCache.shared.getCachedUser(id: $0) == nil }
      guard !missing.isEmpty else { return }
      await ObjectCache.shared.ensure(missing.map { .user($0) })
      loadedUsersGeneration &+= 1
    }
  }

  /// "Can Use" or "Admin" for one person on the list.
  private func rolePicker(userID: Int64, name: String, owned: OwnedAgentGrants) -> some View {
    Picker(
      "Role for \(name)",
      selection: Binding(
        get: { owned.role(userID: userID) ?? .member },
        set: { model.setRole($0, userID: userID, name: name) }
      )
    ) {
      ForEach(BotAccessRole.allCases, id: \.self) { role in
        Text(role.title).tag(role)
      }
    }
    .labelsHidden()
    .pickerStyle(.menu)
    .fixedSize()
    .disabled(model.pending.contains(.user(userID)))
    .help("Admins manage the bot with its owner")
  }

  private func removeButton(_ subject: AgentGrantSubject, name: String) -> some View {
    Button("Remove", role: .destructive) { model.setAccess(false, subject: subject, name: name) }
      .disabled(model.pending.contains(subject))
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

  private func spaceRow(_ space: Space, @ViewBuilder trailing: () -> some View) -> some View {
    subjectRow(
      title: space.displayName,
      detail: "Everyone in this space",
      systemImage: "building.2",
      space: space,
      trailing: trailing
    )
  }

  private func subjectRow(
    title: String,
    detail: LocalizedStringKey,
    systemImage: String,
    space: Space?,
    @ViewBuilder trailing: () -> some View
  ) -> some View {
    HStack(spacing: 10) {
      Group {
        if let space {
          SpaceAvatar(space: space, size: 28)
        } else {
          Image(systemName: systemImage)
            .foregroundStyle(.secondary)
            .frame(width: 28, height: 28)
            .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
      }
      VStack(alignment: .leading, spacing: 1) {
        Text(title).lineLimit(1)
        Text(detail)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
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
}
