import InlineKit
import SwiftUI

/// Output in a chat's Agent Settings: one row for this thread, its menu
/// holding the agent's default as a submenu, like on Mac. Shown for agents
/// that report a runtime. The sheet loads the values (`loadOutputModes`).
struct AgentOutputModeSection: View {
  let peer: Peer
  let botUserID: Int64

  @ObservedObject private var store = AgentWorkStateStore.shared
  @ObservedObject private var grants = AgentGrantStore.shared
  @State private var isUpdating = false

  /// Unknown grants render editable; the server rejects what it must.
  private var canConfigure: Bool {
    grants.access(botUserID: botUserID)?.satisfies(.configure) ?? true
  }

  var body: some View {
    let defaultMode = store.defaultOutputMode(botUserID: botUserID)
    let threadMode = store.outputModeOverride(peer: peer, botUserID: botUserID)
    let defaultTitle = String(localized: "Default (\(defaultMode.title))")
    Section {
      Menu {
        option(defaultTitle, isSelected: threadMode == nil) { setThreadMode(nil) }
        Divider()
        ForEach(AgentThreadOutputMode.allCases, id: \.self) { mode in
          option(mode.title, description: mode.summary, isSelected: threadMode == mode) { setThreadMode(mode) }
        }
        Divider()
        Menu("Agent Default") {
          ForEach(AgentThreadOutputMode.allCases, id: \.self) { mode in
            option(mode.title, description: mode.summary, isSelected: defaultMode == mode) { setDefaultMode(mode) }
          }
        }
      } label: {
        LabeledContent("Output") {
          HStack(spacing: 6) {
            if isUpdating { ProgressView() }
            Text(threadMode?.title ?? defaultTitle)
            if canConfigure {
              Image(systemName: "chevron.up.chevron.down")
                .font(.caption2.weight(.semibold))
            }
          }
        }
        .foregroundStyle(.primary)
      }
      .disabled(!canConfigure || isUpdating)
      .accessibilityLabel("Output")
      .accessibilityValue(threadMode?.title ?? defaultTitle)
    } footer: {
      if canConfigure {
        Text((threadMode ?? defaultMode).summary)
      } else {
        Label("Only the agent’s owner can change how it replies.", systemImage: "lock")
      }
    }
    .task(id: botUserID) {
      grants.ensureLoaded(botUserID: botUserID)
    }
  }

  private func option(
    _ title: String,
    description: String? = nil,
    isSelected: Bool,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      if isSelected {
        Label(title, systemImage: "checkmark")
      } else {
        Text(title)
      }
      if let description { Text(description) }
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
        ToastManager.shared.showToast(
          "Couldn’t change the output mode",
          type: .error,
          systemImage: "exclamationmark.triangle.fill"
        )
      }
    }
  }
}
