#if DEBUG
import Foundation
import InlineProtocol

/// Debug builds only: Settings → Bots for a person with many bots, for the
/// `--peerinfo-harness` Settings → Bots cases. Nothing reaches the server.
public enum BotsSettingsDebugFixture {
  public static var isRequested: Bool { PeerInfoDebugFixture.isRequested }

  public enum Case: String, CaseIterable, Sendable {
    /// The list, with each bot's output and sharing.
    case list = "settings-bots"
    /// Editing (the macOS Edit Bots sheet, iOS edit mode) with three bots selected.
    case editing = "settings-bots-editing"
    /// Editing after Friendly for four bots: one wasn't updated.
    case partialFailure = "settings-bots-partial-failure"

    public var title: String {
      switch self {
        case .list: "Settings → Bots"
        case .editing: "Settings → Bots: editing"
        case .partialFailure: "Settings → Bots: partial failure"
      }
    }
  }

  private static let me = PeerInfoDebugFixture.me

  /// A bot the viewer may use but not change.
  static let notYoursBotID: Int64 = 16

  /// id, name, username, output (nil: doesn't apply one), bridge-run, open to everyone, people shared with.
  private static let rows: [(Int64, String, String, AgentThreadOutputMode?, Bool, Bool, [Int64])] = [
    (10, "Claude on MacBook Air", "mos_claude_mba_7f3", .detailed, true, false, [2]),
    (12, "Research Hermes", "hermes_research_bot", .detailed, false, true, []),
    (13, "Writer Hermes", "hermes_writer_bot", .friendly, false, false, []),
    (14, "Inbox Hermes", "hermes_inbox_bot", .detailed, false, true, []),
    (15, "Codex Studio", "codex_studio_bot", .detailed, true, false, []),
    (16, "Deploy Bot", "deploy_ci_bot", nil, false, true, [2, 5]),
  ]

  /// The bots Settings → Bots lists in the harness.
  public static var settingsBots: [InlineProtocol.User]? {
    guard isRequested else { return nil }
    return rows.map { row in
      .with {
        $0.id = row.0
        $0.firstName = row.1
        $0.username = row.2
        $0.bot = true
      }
    }
  }

  /// Output modes and sharing as the server would report them.
  @MainActor
  public static func seed() {
    guard isRequested else { return }
    let work = AgentWorkStateStore.shared
    let grants = AgentGrantStore.shared
    for (id, _, _, mode, bridge, open, people) in rows {
      if id == notYoursBotID {
        // Leo's bot, shared with the viewer to use: listed, but not theirs to change.
        var listed = InlineProtocol.ListAgentGrantsResult()
        listed.ownerUserID = 4
        listed.revision = 1
        listed.grants = [.with {
          $0.id = id * 10
          $0.botUserID = id
          $0.userID = me
          $0.operations = [.invoke]
          $0.revision = 1
        }]
        grants.apply(listed, botUserID: id, viewerUserID: me)
        continue
      }
      var listed = InlineProtocol.ListAgentGrantsResult()
      listed.ownerUserID = me
      listed.revision = 1
      listed.grants = people.enumerated().map { index, userID in
        .with {
          $0.id = id * 10 + Int64(index)
          $0.botUserID = id
          $0.userID = userID
          $0.operations = [.invoke, .steer]
          $0.revision = 1
        }
      }
      grants.apply(listed, botUserID: id, viewerUserID: me)
      grants.apply(settings: .with {
        $0.botUserID = id
        $0.openToEveryone = open
      })
      guard let mode else { continue }
      if bridge {
        work.apply(runtime: .with {
          $0.botUserID = id
          $0.status = .online
          $0.defaultOutputMode = mode.protocolValue
        })
      } else {
        work.setDeclaresOutputMode(true, botUserID: id)
        work.setDefaultOutputMode(mode, botUserID: id)
      }
    }
  }

  /// The edit-mode state a case starts in. The failure is a sample outcome:
  /// one bot already Friendly, one call timing out.
  @MainActor
  public static func bulkModel(for harnessCase: Case) async -> BotBulkEditModel {
    let model = BotBulkEditModel(
      apply: { action, ids in
        var outcome = BotBulkOutcome(botUserIDs: ids)
        for id in ids {
          outcome.results[id] = switch id {
            case 13: .unchanged
            case 14: .failed(String(localized: "Timed out."))
            default: .changed
          }
        }
        if case let .outputMode(mode) = action {
          for id in outcome.changed { AgentWorkStateStore.shared.setDefaultOutputMode(mode, botUserID: id) }
        }
        return outcome
      },
      isSelectable: { BotBulkSettings.canConfigure(botUserID: $0) != false }
    )
    switch harnessCase {
      case .list:
        break
      case .editing:
        model.beginEditing()
        model.setSelection([12, 13, 14])
      case .partialFailure:
        model.beginEditing()
        model.setSelection([10, 12, 13, 14])
        await model.apply(.outputMode(.friendly), botUserIDs: rows.map(\.0))
    }
    return model
  }
}
#endif
