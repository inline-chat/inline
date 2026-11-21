import InlineKit
import InlineProtocol
import SwiftUI

/// A bot row in edit mode. The list draws the selection circle; a tap selects.
/// Bots the viewer can't change are dimmed and can't be selected.
struct IOSBotSelectableRow: View {
  let bot: InlineProtocol.User
  let isSelectable: Bool
  let note: (text: String, isFailure: Bool)?

  var body: some View {
    IOSManagedBotSummary(bot: bot, isSelectable: isSelectable, note: note)
      .padding(.vertical, 3)
      .opacity(isSelectable ? 1 : 0.45)
      .selectionDisabled(!isSelectable)
  }
}

/// The one bottom-toolbar button in edit mode: Change, with Output and
/// Shared with sections.
struct IOSBotBulkChangeMenu: View {
  let model: BotBulkEditModel
  /// Every listed bot, in list order.
  let botUserIDs: [Int64]

  var body: some View {
    Menu {
      Section("Output") {
        ForEach(AgentThreadOutputMode.allCases, id: \.self) { mode in
          Button(mode.title) { apply(.outputMode(mode)) }
        }
      }
      Section("Shared with") {
        Button("Only me") { apply(.openToEveryone(false)) }
        Button("Everyone") { apply(.openToEveryone(true)) }
      }
    } label: {
      if model.isRunning {
        ProgressView()
      } else {
        Text("Change")
      }
    }
    .disabled(model.isRunning || model.selectedBots(in: botUserIDs).isEmpty)
  }

  private func apply(_ action: BotBulkAction) {
    Task { await model.apply(action, botUserIDs: botUserIDs) }
  }
}

/// "1 bot wasn’t updated · Try again", above the bots, only after a failure.
struct IOSBotBulkFailureSection: View {
  let model: BotBulkEditModel

  var body: some View {
    if let header = model.failureHeader {
      Section {
        HStack {
          Text(header)
            .foregroundStyle(.red)
          Spacer()
          Button("Try again") {
            Task { await model.retryFailed() }
          }
          .disabled(model.isRunning)
        }
      }
    }
  }
}
