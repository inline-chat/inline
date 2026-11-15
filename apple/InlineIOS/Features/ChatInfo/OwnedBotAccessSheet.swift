import Auth
import InlineKit
import InlineUI
import Logger
import RealtimeV2
import SwiftUI

/// Who can reach a bot the viewer owns, from its chat info or a thread's
/// participants: everyone, or the people and spaces the owner adds. Entries
/// are removed in place.
struct BotAccessView: View {
  let bot: UserInfo
  /// A thread's direct participants, offered as toggles. Empty in the bot's own chat.
  var participants: [UserInfo] = []
  /// Shown above the list, e.g. right after the bot was created.
  var introduction: String?

  @ObservedObject private var grants = AgentGrantStore.shared
  @ObservedObject private var work = AgentWorkStateStore.shared
  /// Spaces, groups and the open-to-everyone switch.
  @State private var model: BotAccessListModel
  /// Optimistic values while a grant change is in flight.
  @State private var pendingAccess: [Int64: Bool] = [:]
  @State private var errorMessage: String?
  @State private var isAddingPeople = false
  /// Bumped when people with access finish loading, to re-read the cache.
  @State private var loadedUsersGeneration = 0

  private let log = Log.scoped("BotAccessView")

  init(bot: UserInfo, participants: [UserInfo] = [], introduction: String? = nil) {
    self.bot = bot
    self.participants = participants
    self.introduction = introduction
    _model = State(initialValue: BotAccessListModel(botUserID: bot.user.id))
  }

  private var viewerUserID: Int64? { Auth.shared.getCurrentUserId() }
  /// The bot's real owner, which isn't the viewer when they manage it as an admin.
  private var ownerUserID: Int64? {
    guard let id = grants.access(botUserID: botUserID)?.ownerUserID, id > 0 else { return viewerUserID }
    return id
  }

  private var botUserID: Int64 { bot.user.id }
  private var owned: OwnedAgentGrants? { grants.ownedGrants(botUserID: botUserID) }
  private var botName: String { bot.user.shortDisplayName }
  private var isOpen: Bool { grants.openToEveryoneByBotUserID[botUserID] == true }
  /// A bridge answers only its owner and access list, so opening it would
  /// show people a composer for an agent that refuses them.
  private var offersOpenToEveryone: Bool { !work.runtimeBotUserIDs.contains(botUserID) }
  private var shownError: String? { errorMessage ?? model.errorMessage }

  /// People in this chat who can be given access: not the owner, this bot or other bots.
  private var chatPeople: [UserInfo] {
    let viewerID = Auth.shared.getCurrentUserId()
    return participants.filter { person in
      !person.user.bot && person.user.id != botUserID && person.user.id != viewerID
    }
  }

  /// People with access, minus those already listed under this chat.
  private var grantedUserIDs: [Int64] {
    let inChat = Set(chatPeople.map(\.user.id))
    let ids = (owned?.userIDs ?? []).subtracting(inChat)
    return ids.sorted { displayName($0).localizedCaseInsensitiveCompare(displayName($1)) == .orderedAscending }
  }

  var body: some View {
    List {
      if let introduction {
        Section {
          Label(introduction, systemImage: "lock.fill")
            .foregroundStyle(.secondary)
        }
      }

      if let shownError {
        Section {
          Label(shownError, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.red)
        }
      }

      if offersOpenToEveryone, owned != nil {
        Section {
          Toggle("Anyone Can Message", isOn: Binding(get: { isOpen }, set: { model.setOpenToEveryone($0) }))
            .disabled(model.isChangingOpen)
        } footer: {
          Text(isOpen
            ? "Anyone on Inline can message \(botName) and add it to chats."
            : "For bots meant for everyone, like a support or team bot.")
        }
      }

      Section {
        if let owner = ownerUserID.flatMap(cachedUser) {
          personLabel(owner, subtitle: String(localized: "Owner"))
        }
      }

      if owned == nil, grants.failedBotUserIDs.contains(botUserID) {
        Section {
          Button {
            grants.refresh(botUserID: botUserID)
          } label: {
            Label("Couldn’t load who has access. Try Again", systemImage: "arrow.clockwise")
          }
        }
      } else if owned == nil {
        Section {
          HStack(spacing: 10) {
            ProgressView()
            Text("Loading access…")
              .foregroundStyle(.secondary)
          }
        }
      } else {
        if !chatPeople.isEmpty {
          Section("In This Chat") {
            ForEach(chatPeople) { person in
              Toggle(isOn: accessBinding(person.user.id)) {
                personLabel(person, subtitle: person.user.username.map { "@\($0)" })
              }
              .disabled(pendingAccess[person.user.id] != nil)
            }
          }
        }

        Section {
          ForEach((owned?.spaceIDs ?? []).sorted(), id: \.self) { spaceID in
            let title = model.space(spaceID)?.displayName ?? String(localized: "A space")
            subjectRow(
              .space(spaceID), title: title, detail: "Everyone in this space", space: model.space(spaceID)
            )
          }
          ForEach((owned?.groupIDs ?? []).sorted(), id: \.self) { groupID in
            subjectRow(
              .group(groupID), title: model.groupTitle(groupID), detail: "Everyone in this group", space: nil
            )
          }
          ForEach(grantedUserIDs, id: \.self) { userID in
            grantedRow(userID)
          }

          Button {
            isAddingPeople = true
          } label: {
            Label("Add People", systemImage: "person.badge.plus")
          }

          let groups = model.groupsByID.values
            .filter { owned?.groupIDs.contains($0.id) != true }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
          if !groups.isEmpty {
            Menu {
              ForEach(groups) { group in
                let title = model.groupTitle(group.id)
                Button(title) { model.setAccess(true, subject: .group(group.id), name: title) }
              }
            } label: {
              Label("Add a Group", systemImage: "person.3")
            }
          }

          let spaces = model.spaceMatches("", excluding: owned?.spaceIDs ?? [])
          if !spaces.isEmpty {
            Menu {
              ForEach(spaces) { space in
                Button(space.displayName) {
                  model.setAccess(true, subject: .space(space.id), name: space.displayName)
                }
              }
            } label: {
              Label("Add a Space", systemImage: "building.2")
            }
          }
        } header: {
          Text(participants.isEmpty ? "Shared With" : "Also Shared With")
        } footer: {
          Text("Only you and the people here can message \(botName), mention it or add it to chats. Swipe to remove someone, or touch and hold to make them an admin. Admins manage the bot with its owner; only the owner can delete it.")
        }
      }
    }
    .listStyle(.insetGrouped)
    .navigationTitle("Who Can Message")
    .navigationBarTitleDisplayMode(.inline)
    .animation(.default, value: owned)
    .task(id: botUserID) {
      // The cached list renders first; this only picks up missed changes.
      await model.load()
    }
    .task(id: grantedUserIDs + [ownerUserID ?? 0]) {
      let missing = (grantedUserIDs + [ownerUserID].compactMap(\.self))
        .filter { ObjectCache.shared.getCachedUser(id: $0) == nil }
      guard !missing.isEmpty else { return }
      await ObjectCache.shared.ensure(missing.map { .user($0) })
      loadedUsersGeneration &+= 1
    }
    .sheet(isPresented: $isAddingPeople) {
      BotAccessAddPeopleSheet(bot: bot)
    }
  }

  private func grantedRow(_ userID: Int64) -> some View {
    let isAdmin = owned?.role(userID: userID) == .admin
    let name = cachedUser(userID)?.user.shortDisplayName ?? String(localized: "this person")
    return Group {
      if let userInfo = cachedUser(userID) {
        HStack {
          personLabel(userInfo, subtitle: userInfo.user.username.map { "@\($0)" })
          Spacer()
          if isAdmin {
            Text("Admin")
              .font(.footnote)
              .foregroundStyle(.secondary)
          }
        }
      } else {
        HStack(spacing: 12) {
          Circle().fill(Color(uiColor: .systemGray4)).frame(width: 36, height: 36)
          Text("Loading…").foregroundStyle(.secondary)
        }
      }
    }
    .opacity(pendingAccess[userID] == false ? 0.4 : 1)
    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
      Button("Remove", role: .destructive) { setAccess(false, userID: userID) }
    }
    .contextMenu {
      Button {
        model.setRole(isAdmin ? .member : .admin, userID: userID, name: name)
      } label: {
        Label(
          isAdmin ? "Remove as Admin" : "Make Admin",
          systemImage: isAdmin ? "person.badge.minus" : "person.badge.key"
        )
      }
      Button(role: .destructive) {
        setAccess(false, userID: userID)
      } label: {
        Label("Remove Access", systemImage: "person.badge.minus")
      }
    }
  }

  /// A whole space or group on the list.
  private func subjectRow(
    _ subject: AgentGrantSubject,
    title: String,
    detail: LocalizedStringKey,
    space: Space?
  ) -> some View {
    HStack(spacing: 12) {
      if let space {
        SpaceAvatar(space: space, size: 36)
      } else {
        Image(systemName: "person.3.fill")
          .foregroundStyle(.secondary)
          .frame(width: 36, height: 36)
          .background(Color(uiColor: .systemGray5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
      }
      VStack(alignment: .leading, spacing: 1) {
        Text(title).lineLimit(1)
        Text(detail)
          .font(.footnote)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
    }
    .opacity(model.pending.contains(subject) ? 0.4 : 1)
    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
      Button("Remove", role: .destructive) { model.setAccess(false, subject: subject, name: title) }
    }
    .contextMenu {
      Button(role: .destructive) {
        model.setAccess(false, subject: subject, name: title)
      } label: {
        Label("Remove Access", systemImage: "minus.circle")
      }
    }
  }

  private func personLabel(_ userInfo: UserInfo, subtitle: String?) -> some View {
    HStack(spacing: 12) {
      UserAvatar(userInfo: userInfo, size: 36)
      VStack(alignment: .leading, spacing: 1) {
        Text(userInfo.user.displayName)
          .lineLimit(1)
        if let subtitle {
          Text(subtitle)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      }
    }
  }

  private func cachedUser(_ userID: Int64) -> UserInfo? {
    _ = loadedUsersGeneration
    return ObjectCache.shared.getCachedUser(id: userID)
  }

  private func displayName(_ userID: Int64) -> String {
    ObjectCache.shared.getCachedUser(id: userID)?.user.displayName ?? ""
  }

  private func accessBinding(_ userID: Int64) -> Binding<Bool> {
    Binding(
      get: { pendingAccess[userID] ?? owned?.hasGrant(userID: userID) ?? false },
      set: { setAccess($0, userID: userID) }
    )
  }

  private func setAccess(_ hasAccess: Bool, userID: Int64) {
    guard pendingAccess[userID] == nil else { return }
    pendingAccess[userID] = hasAccess
    errorMessage = nil
    Task {
      defer { pendingAccess[userID] = nil }
      do {
        if hasAccess {
          try await grants.setGrant(botUserID: botUserID, userID: userID)
        } else {
          try await grants.deleteGrant(botUserID: botUserID, userID: userID)
        }
      } catch {
        log.error("Failed to update access for user \(userID) on bot \(botUserID)", error: error)
        errorMessage = hasAccess ? "Couldn’t give access. Try again." : "Couldn’t remove access. Try again."
      }
    }
  }
}

/// Searches people and gives each one tapped access to the bot.
private struct BotAccessAddPeopleSheet: View {
  let bot: UserInfo

  @Environment(\.realtimeV2) private var realtimeV2
  @Environment(\.dismiss) private var dismiss
  @ObservedObject private var grants = AgentGrantStore.shared
  @State private var search: BotAccessPeopleSearch?
  @State private var adding: Set<Int64> = []
  @State private var errorMessage: String?

  private let log = Log.scoped("BotAccessAddPeople")

  private var granted: Set<Int64> {
    grants.ownedGrants(botUserID: bot.user.id)?.userIDs ?? []
  }

  var body: some View {
    NavigationStack {
      List {
        if let errorMessage {
          Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.red)
        }

        if let search {
          if search.query.trimmingCharacters(in: .whitespaces).isEmpty {
            Text("Search by name or username.")
              .foregroundStyle(.secondary)
          } else if search.results.isEmpty, !search.isSearching {
            Text("No people found.")
              .foregroundStyle(.secondary)
          }
          ForEach(search.results) { person in
            resultRow(person)
          }
          if search.isSearching {
            HStack {
              Spacer()
              ProgressView()
              Spacer()
            }
          }
        }
      }
      .listStyle(.insetGrouped)
      .searchable(
        text: Binding(get: { search?.query ?? "" }, set: { search?.query = $0 }),
        placement: .navigationBarDrawer(displayMode: .always),
        prompt: "Name or username"
      )
      .navigationTitle("Add People")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
        }
      }
    }
    .onAppear {
      if search == nil {
        search = BotAccessPeopleSearch(botUserID: bot.user.id, realtime: realtimeV2)
      }
    }
    .onDisappear { search?.cancel() }
  }

  private func resultRow(_ person: UserInfo) -> some View {
    let hasAccess = granted.contains(person.user.id)
    return Button {
      add(person)
    } label: {
      HStack(spacing: 12) {
        UserAvatar(userInfo: person, size: 36)
        VStack(alignment: .leading, spacing: 1) {
          Text(person.user.displayName)
            .foregroundStyle(.primary)
            .lineLimit(1)
          if let username = person.user.username, !username.isEmpty {
            Text("@\(username)")
              .font(.footnote)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)

        if adding.contains(person.user.id) {
          ProgressView()
        } else if hasAccess {
          Image(systemName: "checkmark.circle.fill")
            .foregroundStyle(Color.green)
            .font(.title3)
        } else {
          Image(systemName: "plus.circle")
            .foregroundStyle(Color.accentColor)
            .font(.title3)
        }
      }
    }
    .buttonStyle(.plain)
    .disabled(hasAccess || adding.contains(person.user.id))
    .accessibilityLabel(hasAccess ? "\(person.user.displayName), has access" : "Give \(person.user.displayName) access")
  }

  private func add(_ person: UserInfo) {
    let userID = person.user.id
    guard !adding.contains(userID) else { return }
    adding.insert(userID)
    errorMessage = nil
    Task {
      defer { adding.remove(userID) }
      do {
        try await grants.setGrant(botUserID: bot.user.id, userID: userID)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
      } catch {
        log.error("Failed to give user \(userID) access to bot \(bot.user.id)", error: error)
        errorMessage = "Couldn’t give \(person.user.shortDisplayName) access. Try again."
      }
    }
  }
}

/// A bot's access list from a thread's participants, as its own sheet.
struct OwnedBotAccessSheet: View {
  let bot: UserInfo
  let participants: [UserInfo]
  var introduction: String?
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      BotAccessView(bot: bot, participants: participants, introduction: introduction)
        .toolbar {
          ToolbarItem(placement: .confirmationAction) {
            Button("Done") { dismiss() }
          }
        }
    }
  }
}

/// Marks a participant who has access to the selected bot.
struct AgentAccessBadge: View {
  var size: CGFloat = 20

  var body: some View {
    Image(systemName: "checkmark.circle.fill")
      .font(.system(size: size, weight: .semibold))
      .symbolRenderingMode(.palette)
      .foregroundStyle(.white, Color(uiColor: .systemGreen))
      .background(
        Circle()
          .fill(Color(uiColor: .secondarySystemGroupedBackground))
          .padding(-2)
      )
      .accessibilityHidden(true)
  }
}
