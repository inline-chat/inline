import Auth
import InlineKit
import InlineMacUI
import InlineProtocol
import SwiftUI

/// Output in Agent Settings (spec §6, Oct 26): one row for this thread, its
/// menu holding the agent's default as a submenu. Never in Compose. Values
/// come from the server and render from the local cache first.
struct AgentOutputModeSettingsRow: View {
  let peer: InlineKit.Peer
  let botUserID: Int64
  @ObservedObject private var store = AgentWorkStateStore.shared
  @ObservedObject private var grants = AgentGrantStore.shared
  @State private var isUpdating = false

  /// Unknown grants render editable; the server rejects what it must.
  static func canConfigure(botUserID: Int64) -> Bool {
    AgentGrantStore.shared.access(botUserID: botUserID)?.satisfies(.configure) ?? true
  }

  var body: some View {
    let defaultMode = store.defaultOutputMode(botUserID: botUserID)
    let threadMode = store.outputModeOverride(peer: peer, botUserID: botUserID)
    let defaultTitle = String(localized: "Default (\(defaultMode.title))")
    AgentSettingsRow("Output", isPending: isUpdating) {
      AgentSettingsMenu(
        threadMode?.title ?? defaultTitle,
        accessibilityLabel: "Output",
        isEditable: Self.canConfigure(botUserID: botUserID)
      ) {
        AgentSettingsMenuItem(defaultTitle, isSelected: threadMode == nil) {
          setThreadMode(nil)
        }
        Divider()
        ForEach(AgentThreadOutputMode.allCases, id: \.self) { mode in
          AgentSettingsMenuItem(mode.title, description: mode.summary, isSelected: threadMode == mode) {
            setThreadMode(mode)
          }
        }
        Divider()
        Menu("Agent Default") {
          ForEach(AgentThreadOutputMode.allCases, id: \.self) { mode in
            AgentSettingsMenuItem(mode.title, description: mode.summary, isSelected: defaultMode == mode) {
              setDefaultMode(mode)
            }
          }
        }
      }
      .disabled(isUpdating)
    }
    .help((threadMode ?? defaultMode).summary)
  }

  private func setThreadMode(_ mode: AgentThreadOutputMode?) {
    guard mode != store.outputModeOverride(peer: peer, botUserID: botUserID) else { return }
    perform { try await store.updateOutputModeOverride(mode, peer: peer, botUserID: botUserID) }
  }

  private func setDefaultMode(_ mode: AgentThreadOutputMode) {
    guard mode != store.defaultOutputMode(botUserID: botUserID) else { return }
    perform { try await store.updateDefaultOutputMode(mode, botUserID: botUserID) }
  }

  private func perform(_ operation: @escaping () async throws -> Void) {
    guard !isUpdating else { return }
    isUpdating = true
    Task { @MainActor in
      defer { isUpdating = false }
      do {
        try await operation()
      } catch {
        ToastCenter.shared.showError("Couldn’t change the output mode.")
      }
    }
  }
}

enum AgentOutputModeSettingsLoader {
  /// Loads the agent default and this chat's override when Agent Settings opens.
  @MainActor
  static func load(peer: InlineKit.Peer, botUserID: Int64) async {
    AgentGrantStore.shared.ensureLoaded(botUserID: botUserID)
    await AgentWorkStateStore.shared.loadOutputModes(peer: peer, botUserID: botUserID)
  }
}
