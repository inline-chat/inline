import InlineKit
import InlineProtocol
import InlineUI
import Logger
import RealtimeV2
import SwiftUI
import UIKit

struct BotsSettingsView: View {
  @Environment(\.realtimeV2) private var realtimeV2

  @State private var bots: [InlineProtocol.User] = []
  @State private var name = ""
  @State private var username = ""
  @State private var revealedTokens: [Int64: String] = [:]
  @State private var busyBotIDs: Set<Int64> = []
  @State private var isLoading = false
  @State private var isCreating = false
  @State private var errorMessage: String?
  @State private var botToDelete: InlineProtocol.User?

  var body: some View {
    List {
      Section {
        TextField("Bot Name", text: $name)
          .textContentType(.name)

        HStack(spacing: 2) {
          Text("@", comment: "Fixed prefix shown before an editable bot username.")
            .foregroundStyle(.secondary)
          TextField("username_bot", text: $username)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        }

        Button {
          createBot()
        } label: {
          if isCreating {
            HStack {
              ProgressView()
              Text("Creating Bot…")
            }
          } else {
            Label("Create Bot", systemImage: "plus")
          }
        }
        .disabled(!canCreate)
      } header: {
        Text("Create Bot")
      } footer: {
        Text("Bot usernames must end with “bot”. You can create up to five bots.")
      }

      if let errorMessage {
        Section {
          Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.red)
        }
      }

      Section("Your Bots") {
        if isLoading, bots.isEmpty {
          HStack {
            ProgressView()
            Text("Loading bots…")
              .foregroundStyle(.secondary)
          }
        } else if bots.isEmpty {
          ContentUnavailableView(
            "No Bots Yet",
            systemImage: "cpu",
            description: Text("Create a bot for integrations and automated workflows.")
          )
        } else {
          ForEach(bots, id: \.id) { bot in
            IOSBotSettingsRow(
              bot: bot,
              token: revealedTokens[bot.id],
              isBusy: busyBotIDs.contains(bot.id),
              revealToken: { revealToken(for: bot.id) },
              hideToken: { revealedTokens[bot.id] = nil },
              copyToken: copyToken,
              requestDelete: { botToDelete = bot }
            )
          }
        }
      }
    }
    .listStyle(.insetGrouped)
    .navigationTitle("Bots")
    .navigationBarTitleDisplayMode(.inline)
    .refreshable {
      await loadBots()
    }
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Button {
          Task { await loadBots() }
        } label: {
          Label("Refresh Bots", systemImage: "arrow.clockwise")
        }
        .disabled(isLoading)
      }
    }
    .confirmationDialog(
      "Delete Bot?",
      isPresented: Binding(
        get: { botToDelete != nil },
        set: { if !$0 { botToDelete = nil } }
      ),
      titleVisibility: .visible
    ) {
      Button("Delete Bot", role: .destructive) {
        guard let bot = botToDelete else { return }
        botToDelete = nil
        deleteBot(bot.id)
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("This revokes the bot token. Existing messages remain in history.")
    }
    .task {
      await loadBots()
    }
  }

  private var sanitizedUsername: String {
    var value = username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    while value.hasPrefix("@") {
      value.removeFirst()
    }
    return value
  }

  private var canCreate: Bool {
    !isCreating
      && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && sanitizedUsername.hasSuffix("bot")
      && bots.count < 5
  }

  private func loadBots() async {
    guard !isLoading else { return }
    isLoading = true
    errorMessage = nil
    defer { isLoading = false }

    do {
      let result = try await realtimeV2.send(.listBots())
      guard case let .listBots(response) = result else {
        throw TransactionExecutionError.invalid
      }
      bots = response.bots.sorted { $0.id < $1.id }
      let validIDs = Set(bots.map(\.id))
      revealedTokens = revealedTokens.filter { validIDs.contains($0.key) }
    } catch {
      Log.scoped("IOSSettings.Bots").error("Failed to load bots", error: error)
      errorMessage = "Could not load bots. Pull to try again."
    }
  }

  private func createBot() {
    let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let candidate = sanitizedUsername
    guard canCreate else { return }

    isCreating = true
    errorMessage = nil
    Task {
      do {
        let result = try await realtimeV2.send(.createBot(name: trimmedName, username: candidate))
        guard case let .createBot(response) = result, response.hasBot else {
          throw TransactionExecutionError.invalid
        }
        bots.append(response.bot)
        bots.sort { $0.id < $1.id }
        if !response.token.isEmpty {
          revealedTokens[response.bot.id] = response.token
        }
        name = ""
        username = ""
      } catch {
        Log.scoped("IOSSettings.Bots").error("Failed to create bot", error: error)
        errorMessage = "Could not create the bot. Check the name and username, then try again."
      }
      isCreating = false
    }
  }

  private func revealToken(for botID: Int64) {
    guard !busyBotIDs.contains(botID) else { return }
    busyBotIDs.insert(botID)
    errorMessage = nil

    Task {
      do {
        let result = try await realtimeV2.send(.revealBotToken(botUserId: botID))
        guard case let .revealBotToken(response) = result, !response.token.isEmpty else {
          throw TransactionExecutionError.invalid
        }
        revealedTokens[botID] = response.token
      } catch {
        Log.scoped("IOSSettings.Bots").error("Failed to reveal bot token", error: error)
        errorMessage = "Could not reveal the bot token."
      }
      busyBotIDs.remove(botID)
    }
  }

  private func deleteBot(_ botID: Int64) {
    guard !busyBotIDs.contains(botID) else { return }
    busyBotIDs.insert(botID)
    errorMessage = nil

    Task {
      do {
        let result = try await realtimeV2.send(.deleteBot(botUserId: botID))
        guard case .deleteBot = result else {
          throw TransactionExecutionError.invalid
        }
        bots.removeAll { $0.id == botID }
        revealedTokens[botID] = nil
      } catch {
        Log.scoped("IOSSettings.Bots").error("Failed to delete bot", error: error)
        errorMessage = "Could not delete the bot."
      }
      busyBotIDs.remove(botID)
    }
  }

  private func copyToken(_ token: String) {
    UIPasteboard.general.string = token
    ToastManager.shared.showToast("Token copied", type: .success, systemImage: "doc.on.doc.fill")
  }
}

private struct IOSBotSettingsRow: View {
  let bot: InlineProtocol.User
  let token: String?
  let isBusy: Bool
  let revealToken: () -> Void
  let hideToken: () -> Void
  let copyToken: (String) -> Void
  let requestDelete: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 10) {
        UserAvatar(user: User(from: bot), size: 38)

        VStack(alignment: .leading, spacing: 2) {
          Text(User(from: bot).displayName)
          if bot.hasUsername, !bot.username.isEmpty {
            Text("@\(bot.username)")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)

        if isBusy {
          ProgressView()
            .controlSize(.small)
        } else {
          Menu {
            if token == nil {
              Button("Reveal Token", action: revealToken)
            } else {
              Button("Hide Token", action: hideToken)
            }

            // TODO: Add profile/avatar editing and token rotation after the
            // second-pass information architecture is verified on device.
            Divider()
            Button("Delete Bot", role: .destructive, action: requestDelete)
          } label: {
            Image(systemName: "ellipsis.circle")
              .foregroundStyle(.secondary)
          }
        }
      }

      if let token {
        HStack(spacing: 8) {
          Text(token)
            .font(.caption.monospaced())
            .lineLimit(1)
            .truncationMode(.middle)
            .privacySensitive()
            .frame(maxWidth: .infinity, alignment: .leading)

          Button("Copy") {
            copyToken(token)
          }
          .buttonStyle(.borderless)
        }
        .padding(.leading, 48)
      }
    }
    .padding(.vertical, 3)
  }
}
