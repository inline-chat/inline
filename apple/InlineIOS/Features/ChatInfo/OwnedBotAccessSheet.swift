import Auth
import InlineKit
import InlineUI
import Logger
import RealtimeV2
import SwiftUI

/// Who may use a bot the viewer owns, from its chat info or a thread's
/// participants. The owner adds people by search and removes them in place.
struct BotAccessView: View {
  let bot: UserInfo
  /// A thread's direct participants, offered as toggles. Empty in the bot's own chat.
  var participants: [UserInfo] = []

  @ObservedObject private var grants = AgentGrantStore.shared
  /// Optimistic values while a grant change is in flight.
  @State private var pendingAccess: [Int64: Bool] = [:]
  @State private var errorMessage: String?
  @State private var isAddingPeople = false
  /// Bumped when people with access finish loading, to re-read the cache.
  @State private var loadedUsersGeneration = 0

  private let log = Log.scoped("BotAccessView")

  private var botUserID: Int64 { bot.user.id }
  private var owned: OwnedAgentGrants? { grants.ownedGrants(botUserID: botUserID) }
  private var botName: String { bot.user.shortDisplayName }

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
      if let errorMessage {
        Section {
          Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.red)
        }
      }

      Section {
        if let viewer = Auth.shared.getCurrentUserId().flatMap(cachedUser) {
          personLabel(viewer, subtitle: String(localized: "Owner"))
        }
      }

      if owned == nil {
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
          ForEach(grantedUserIDs, id: \.self) { userID in
            grantedRow(userID)
          }

          Button {
            isAddingPeople = true
          } label: {
            Label("Add People", systemImage: "person.badge.plus")
          }
        } header: {
          Text(participants.isEmpty ? "People With Access" : "Others With Access")
        } footer: {
          Text("People with access can start and steer \(botName) in chats they share with it. Swipe to remove someone.")
        }
      }
    }
    .listStyle(.insetGrouped)
    .navigationTitle("Shared With")
    .navigationBarTitleDisplayMode(.inline)
    .animation(.default, value: owned?.userIDs)
    .task(id: botUserID) {
      // The cached list renders first; this only picks up missed changes.
      grants.refresh(botUserID: botUserID)
    }
    .task(id: grantedUserIDs) {
      let missing = grantedUserIDs.filter { ObjectCache.shared.getCachedUser(id: $0) == nil }
      guard !missing.isEmpty else { return }
      await ObjectCache.shared.ensure(missing.map { .user($0) })
      loadedUsersGeneration &+= 1
    }
    .sheet(isPresented: $isAddingPeople) {
      BotAccessAddPeopleSheet(bot: bot)
    }
  }

  private func grantedRow(_ userID: Int64) -> some View {
    Group {
      if let userInfo = cachedUser(userID) {
        personLabel(userInfo, subtitle: userInfo.user.username.map { "@\($0)" })
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
      Button(role: .destructive) {
        setAccess(false, userID: userID)
      } label: {
        Label("Remove Access", systemImage: "person.badge.minus")
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
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      BotAccessView(bot: bot, participants: participants)
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
