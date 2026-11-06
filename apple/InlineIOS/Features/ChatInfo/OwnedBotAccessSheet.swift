import Auth
import InlineKit
import InlineProtocol
import InlineUI
import Logger
import RealtimeV2
import SwiftUI

/// Manages a bot the viewer owns from a chat's info: its name and who may use it.
struct OwnedBotAccessSheet: View {
  let bot: UserInfo
  /// The chat's direct participants, offered for access in place.
  let participants: [UserInfo]

  @Environment(\.realtimeV2) private var realtimeV2
  @Environment(\.dismiss) private var dismiss
  @ObservedObject private var grants = AgentGrantStore.shared

  @State private var name: String
  @State private var savedName: String
  @State private var isSavingName = false
  /// Optimistic toggle values while a grant change is in flight.
  @State private var pendingAccess: [Int64: Bool] = [:]
  @State private var errorMessage: String?
  /// Bumped when people outside the chat finish loading, to re-read the cache.
  @State private var loadedUsersGeneration = 0

  private let log = Log.scoped("OwnedBotAccessSheet")

  init(bot: UserInfo, participants: [UserInfo]) {
    self.bot = bot
    self.participants = participants
    let name = bot.user.displayName
    _name = State(initialValue: name)
    _savedName = State(initialValue: name)
  }

  private var botUserID: Int64 { bot.user.id }

  private var owned: OwnedAgentGrants? {
    grants.ownedGrants(botUserID: botUserID)
  }

  private var trimmedName: String {
    name.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var displayName: String {
    savedName.isEmpty ? "Bot" : savedName
  }

  /// People in this chat who can be given access: not the owner, this bot or other bots.
  private var chatPeople: [UserInfo] {
    let viewerID = Auth.shared.getCurrentUserId()
    return participants.filter { person in
      !person.user.bot && person.user.id != botUserID && person.user.id != viewerID
    }
  }

  /// People with access who are not listed under this chat.
  private var otherGrantedUserIDs: [Int64] {
    let inChat = Set(chatPeople.map(\.user.id))
    return (owned?.userIDs ?? []).subtracting(inChat).sorted()
  }

  var body: some View {
    NavigationStack {
      List {
        Section {
          VStack(spacing: 6) {
            UserAvatar(userInfo: bot, size: 72)
            if let username = bot.user.username, !username.isEmpty {
              Text("@\(username)")
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
          }
          .frame(maxWidth: .infinity)
          .listRowBackground(Color.clear)
        }

        Section("Name") {
          TextField("Bot Name", text: $name)
            .textContentType(.name)
            .submitLabel(.done)
            .onSubmit { Task { await saveName() } }
            .disabled(isSavingName)
        }

        if let errorMessage {
          Section {
            Text(errorMessage)
              .font(.footnote)
              .foregroundStyle(.red)
          }
        }

        Section {
          if chatPeople.isEmpty {
            Text("No one else is in this chat.")
              .foregroundStyle(.secondary)
          }
          ForEach(chatPeople) { person in
            accessRow(userID: person.user.id, userInfo: person)
          }
        } header: {
          Text("In This Chat")
        } footer: {
          Text("People with access can start and steer \(displayName). You always have access.")
        }

        if !otherGrantedUserIDs.isEmpty {
          Section("Others With Access") {
            ForEach(otherGrantedUserIDs, id: \.self) { userID in
              accessRow(userID: userID, userInfo: cachedUser(userID))
            }
          }
        }
      }
      .listStyle(.insetGrouped)
      .scrollDismissesKeyboard(.interactively)
      .navigationTitle(displayName)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          if isSavingName {
            ProgressView()
          } else {
            Button("Done") {
              Task {
                if await saveName() { dismiss() }
              }
            }
          }
        }
      }
      .task(id: botUserID) {
        // The cached list renders first; this only picks up missed changes.
        grants.refresh(botUserID: botUserID)
      }
      .task(id: otherGrantedUserIDs) {
        let missing = otherGrantedUserIDs.filter { ObjectCache.shared.getCachedUser(id: $0) == nil }
        guard !missing.isEmpty else { return }
        await ObjectCache.shared.ensure(missing.map { .user($0) })
        loadedUsersGeneration &+= 1
      }
    }
  }

  private func cachedUser(_ userID: Int64) -> UserInfo? {
    _ = loadedUsersGeneration
    return ObjectCache.shared.getCachedUser(id: userID)
  }

  private func accessRow(userID: Int64, userInfo: UserInfo?) -> some View {
    Toggle(isOn: accessBinding(userID)) {
      HStack(spacing: 12) {
        if let userInfo {
          UserAvatar(userInfo: userInfo, size: 32)
        } else {
          Image(systemName: "person.crop.circle.fill")
            .font(.system(size: 32))
            .foregroundStyle(.secondary)
        }

        VStack(alignment: .leading, spacing: 1) {
          Text(userInfo?.user.displayName ?? "Unknown User")
            .lineLimit(1)
          if let username = userInfo?.user.username, !username.isEmpty {
            Text("@\(username)")
              .font(.footnote)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
        }
      }
    }
    .disabled(owned == nil || pendingAccess[userID] != nil)
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

  /// Saves a changed name. Returns false when saving failed.
  @discardableResult
  private func saveName() async -> Bool {
    let newName = trimmedName
    guard !isSavingName, !newName.isEmpty, newName != savedName else {
      if newName.isEmpty { name = savedName }
      return true
    }
    isSavingName = true
    errorMessage = nil
    defer { isSavingName = false }

    do {
      let result = try await realtimeV2.send(.updateBotProfile(botUserId: botUserID, name: newName))
      guard case let .updateBotProfile(response) = result else {
        throw TransactionExecutionError.invalid
      }
      try await AppDatabase.shared.dbWriter.write { db in
        _ = try User.save(db, user: response.bot)
      }
      savedName = User(from: response.bot).displayName
      name = savedName
      return true
    } catch {
      log.error("Failed to rename bot \(botUserID)", error: error)
      errorMessage = "Couldn’t rename the bot. Try again."
      return false
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
