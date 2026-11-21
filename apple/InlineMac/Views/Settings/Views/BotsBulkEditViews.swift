import InlineKit
import InlineProtocol
import InlineUI
import SwiftUI

/// Edit… beside the Your Bots header: opens the Edit Bots sheet.
struct BotBulkEditButton: View {
  let model: BotBulkEditModel

  var body: some View {
    Button("Edit…") { model.beginEditing() }
      .controlSize(.small)
      .help("Change several bots at once")
  }
}

/// "Detailed · You + 1" under a bot: its output and who it's shared with.
struct BotSettingsSubtitleLabel: View {
  let botUserID: Int64
  /// Managed as an admin rather than owned.
  var isAdmin = false
  @ObservedObject private var grants = AgentGrantStore.shared
  @ObservedObject private var work = AgentWorkStateStore.shared

  var body: some View {
    Group {
      if let text = BotSettingsSubtitle.text(botUserID: botUserID, work: work, grants: grants) {
        Text(isAdmin ? "\(text) · Admin" : text)
      } else if isAdmin {
        Text("Admin")
      }
    }
    .font(.caption)
    .foregroundStyle(.secondary)
    .task(id: botUserID) {
      grants.ensureLoaded(botUserID: botUserID)
      await work.loadBotSettings(botUserID: botUserID)
    }
  }
}

/// Edit Bots: every bot in a table with its Output and Shared with, editable
/// in place, and Change for the selected rows. Changes apply right away, so
/// the only button is Done.
struct BotEditSheet: View {
  let bots: [InlineProtocol.User]
  let model: BotBulkEditModel
  let onDone: () -> Void

  private struct Row: Identifiable {
    let id: Int64
    let bot: InlineProtocol.User
  }

  private var rows: [Row] { bots.map { Row(id: $0.id, bot: $0) } }
  private var botIDs: [Int64] { bots.map(\.id) }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 2) {
        Text("Edit Bots")
          .font(.headline)
        Text("Changes apply right away. Select several bots to change them together.")
          .font(.callout)
          .foregroundStyle(.secondary)
      }
      .padding([.horizontal, .top], 20)
      .padding(.bottom, 12)

      Table(rows, selection: Binding(get: { model.selection }, set: { model.setSelection($0) })) {
        TableColumn("Bot") { row in
          BotEditBotCell(bot: row.bot, isEditable: model.isSelectable(row.id), note: model.rowNote(for: row.id))
        }
        TableColumn("Output") { row in
          BotEditOutputCell(botUserID: row.id, model: model)
        }
        .width(min: 110, ideal: 120, max: 150)
        TableColumn("Shared with") { row in
          BotEditSharingCell(botUserID: row.id, model: model)
        }
        .width(min: 120, ideal: 130, max: 170)
      }
      .contextMenu(forSelectionType: Int64.self) { ids in
        // Finder-style: a right-click acts on the clicked selection.
        BotBulkChangeItems { action in
          Task { await model.apply(action, to: botIDs.filter(ids.contains)) }
        }
      }
      .padding(.horizontal, 20)

      HStack(spacing: 10) {
        Menu("Change") {
          BotBulkChangeItems { action in
            Task { await model.apply(action, botUserIDs: botIDs) }
          }
        }
        .fixedSize()
        .disabled(model.selectedBots(in: botIDs).isEmpty)

        Text("\(model.selectedBots(in: botIDs).count) selected")
          .foregroundStyle(.secondary)

        Spacer(minLength: 12)

        if model.isRunning {
          ProgressView()
            .controlSize(.small)
        } else if let header = model.failureHeader {
          Text(header)
            .foregroundStyle(.red)
          Button("Try Again") {
            Task { await model.retryFailed() }
          }
        }

        Button("Done", action: onDone)
          .keyboardShortcut(.defaultAction)
      }
      .padding(20)
    }
    .frame(minWidth: 640, idealWidth: 680, minHeight: 420, idealHeight: 480)
  }
}

/// Output: Detailed, Friendly. Shared with: Only me, Everyone.
struct BotBulkChangeItems: View {
  let apply: (BotBulkAction) -> Void

  var body: some View {
    Section("Output") {
      ForEach(AgentThreadOutputMode.allCases, id: \.self) { mode in
        Button(mode.title) { apply(.outputMode(mode)) }
      }
    }
    Section("Shared with") {
      Button("Only me") { apply(.openToEveryone(false)) }
      Button("Everyone") { apply(.openToEveryone(true)) }
    }
  }
}

/// Avatar, name and @username; a red alert when the last change didn't
/// update the bot (the tooltip says why). Bots you can't change are dimmed.
private struct BotEditBotCell: View {
  let bot: InlineProtocol.User
  let isEditable: Bool
  let note: (text: String, isFailure: Bool)?

  var body: some View {
    HStack(spacing: 8) {
      UserAvatar(user: User(from: bot), size: 24)
      VStack(alignment: .leading, spacing: 0) {
        Text(User(from: bot).displayName)
          .lineLimit(1)
        if bot.hasUsername, !bot.username.isEmpty {
          Text("@\(bot.username)")
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      }
      Spacer(minLength: 4)
      if let note, note.isFailure {
        Image(systemName: "exclamationmark.triangle.fill")
          .foregroundStyle(.red)
          .help(note.text)
          .accessibilityLabel(note.text)
      }
    }
    .padding(.vertical, 2)
    .opacity(isEditable ? 1 : 0.45)
    .help(isEditable ? "" : BotSettingsSubtitle.notYours)
  }
}

/// The bot's Default Output as a pop-up; a dash for bots without one.
private struct BotEditOutputCell: View {
  let botUserID: Int64
  let model: BotBulkEditModel
  @ObservedObject private var work = AgentWorkStateStore.shared

  var body: some View {
    if work.offersOutputMode(botUserID: botUserID) {
      Picker("Output", selection: Binding(
        get: { work.defaultOutputMode(botUserID: botUserID) },
        set: { mode in Task { await model.apply(.outputMode(mode), to: [botUserID]) } }
      )) {
        ForEach(AgentThreadOutputMode.allCases, id: \.self) { mode in
          Text(mode.title).tag(mode)
        }
      }
      .labelsHidden()
      .fixedSize()
      .disabled(!model.isSelectable(botUserID) || model.busyBots.contains(botUserID))
      .opacity(model.isSelectable(botUserID) ? 1 : 0.45)
    } else {
      Text("—")
        .foregroundStyle(.tertiary)
        .help("This bot doesn’t use an output mode")
    }
  }
}

/// Who can message the bot, as a pop-up showing "Only you", "You + 1" or
/// "Everyone". Only me keeps people added one by one. A bot an agent bridge
/// runs can't be opened to everyone, so it offers only Only me.
private struct BotEditSharingCell: View {
  let botUserID: Int64
  let model: BotBulkEditModel
  @ObservedObject private var grants = AgentGrantStore.shared
  @ObservedObject private var work = AgentWorkStateStore.shared

  var body: some View {
    let open = grants.openToEveryoneByBotUserID[botUserID] == true
    Menu {
      Toggle("Only me", isOn: Binding(get: { !open }, set: { _ in change(open: false) }))
      if !work.runtimeBotUserIDs.contains(botUserID) || open {
        Toggle("Everyone", isOn: Binding(get: { open }, set: { _ in change(open: true) }))
      }
    } label: {
      Text(summary)
    }
    .fixedSize()
    .disabled(!model.isSelectable(botUserID) || model.busyBots.contains(botUserID))
    .opacity(model.isSelectable(botUserID) ? 1 : 0.45)
  }

  private var summary: String {
    guard let owned = grants.ownedGrants(botUserID: botUserID) else { return "—" }
    return owned.compactSharingSummary(openToEveryone: grants.openToEveryoneByBotUserID[botUserID] == true)
  }

  private func change(open: Bool) {
    Task { await model.apply(.openToEveryone(open), to: [botUserID]) }
  }
}
