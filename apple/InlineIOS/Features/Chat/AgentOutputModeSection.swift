import InlineKit
import SwiftUI

/// Output mode in a chat's Agent Settings: this thread's override and the
/// agent's default. Shown for agents that report a runtime, like on Mac.
/// The sheet loads the values (`loadOutputModes`).
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
    Section {
      Picker("This Thread", selection: threadSelection) {
        Text("Agent Default (\(defaultMode.title))").tag(AgentThreadOutputMode?.none)
        ForEach(AgentThreadOutputMode.allCases, id: \.self) { mode in
          Text(mode.title).tag(Optional(mode))
        }
      }
      Picker("Agent Default", selection: defaultSelection) {
        ForEach(AgentThreadOutputMode.allCases, id: \.self) { mode in
          Text(mode.title).tag(mode)
        }
      }
    } header: {
      Text("Output")
    } footer: {
      if canConfigure {
        Text((threadMode ?? defaultMode).summary)
      } else {
        Text("Only the agent’s owner can change how it replies.")
      }
    }
    .disabled(!canConfigure || isUpdating)
    .task(id: botUserID) {
      grants.ensureLoaded(botUserID: botUserID)
    }
  }

  private var threadSelection: Binding<AgentThreadOutputMode?> {
    Binding(
      get: { store.outputModeOverride(peer: peer, botUserID: botUserID) },
      set: { mode in
        guard mode != store.outputModeOverride(peer: peer, botUserID: botUserID) else { return }
        perform { try await store.updateOutputModeOverride(mode, peer: peer, botUserID: botUserID) }
      }
    )
  }

  private var defaultSelection: Binding<AgentThreadOutputMode> {
    Binding(
      get: { store.defaultOutputMode(botUserID: botUserID) },
      set: { mode in
        guard mode != store.defaultOutputMode(botUserID: botUserID) else { return }
        perform { try await store.updateDefaultOutputMode(mode, botUserID: botUserID) }
      }
    )
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
