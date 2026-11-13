import Auth
import InlineKit
import InlineMacUI
import InlineProtocol
import SwiftUI

/// Output in Agent Settings (spec §6, Oct 26) and in a bot's chat info: one
/// row for this thread, its menu holding the agent's default as a submenu.
/// Never in Compose. Values come from the server and render from the local
/// cache first.
struct AgentOutputModeSettingsRow: View {
  enum Style {
    /// A full row in the Agent Settings popover.
    case agentSettings
    /// Only the trailing picker, for a chat info row.
    case chatInfo
  }

  let peer: InlineKit.Peer
  let botUserID: Int64
  var style: Style = .agentSettings
  @ObservedObject private var store = AgentWorkStateStore.shared
  @ObservedObject private var grants = AgentGrantStore.shared
  @State private var isUpdating = false

  /// Unknown grants render editable; the server rejects what it must.
  static func canConfigure(botUserID: Int64) -> Bool {
    AgentGrantStore.shared.access(botUserID: botUserID)?.satisfies(.configure) ?? true
  }

  private static let lockReason = String(localized: "Only the agent’s owner can change how it replies.")

  var body: some View {
    let canConfigure = Self.canConfigure(botUserID: botUserID)
    let mode = store.outputMode(peer: peer, botUserID: botUserID)
    switch style {
    case .agentSettings:
      AgentSettingsRow("Output", isPending: isUpdating) {
        AgentSettingsMenu(
          value,
          accessibilityLabel: "Output",
          isEditable: canConfigure
        ) {
          menuItems
        }
        .disabled(isUpdating)
      }
      .help(mode.summary)
    case .chatInfo:
      HStack(spacing: 6) {
        if isUpdating {
          ProgressView()
            .controlSize(.mini)
            .accessibilityLabel("Updating Output")
        }
        Menu {
          menuItems
        } label: {
          InlineMenuPickerLabel(title: value, systemImage: mode.systemImage, disabled: !canConfigure)
        }
        .menuStyle(.borderlessButton)
        .buttonStyle(.plain)
        .fixedSize()
        .disabled(!canConfigure || isUpdating)
        .accessibilityLabel("Output")
        .accessibilityValue(value)
      }
      .help(canConfigure ? mode.summary : Self.lockReason)
    }
  }

  /// This thread's choice, else "Default (…)".
  private var value: String {
    store.outputModeOverride(peer: peer, botUserID: botUserID)?.title ?? defaultTitle
  }

  private var defaultTitle: String {
    String(localized: "Default (\(store.defaultOutputMode(botUserID: botUserID).title))")
  }

  @ViewBuilder
  private var menuItems: some View {
    let defaultMode = store.defaultOutputMode(botUserID: botUserID)
    let threadMode = store.outputModeOverride(peer: peer, botUserID: botUserID)
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

private extension AgentThreadOutputMode {
  var systemImage: String {
    switch self {
    case .detailed: "list.bullet.rectangle"
    case .friendly: "bubble.left"
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
