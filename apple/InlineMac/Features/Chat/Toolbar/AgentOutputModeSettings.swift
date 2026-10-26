import Auth
import InlineKit
import InlineProtocol
import SwiftUI

/// Output mode in Agent Settings (spec §6, Oct 26): the agent's default and
/// this thread's override. Never in Compose. Values come from the server and
/// render from the local cache first.
struct AgentOutputModeSettingsSection: View {
  let peer: InlineKit.Peer
  let botUserID: Int64
  @ObservedObject private var store = AgentWorkStateStore.shared
  @ObservedObject private var grants = AgentGrantStore.shared
  @State private var isUpdating = false

  private var access: AgentGrantAccess? { grants.access(botUserID: botUserID) }

  /// Unknown grants render editable; the server rejects what it must.
  private var canConfigure: Bool { access?.satisfies(.configure) ?? true }

  private var botName: String {
    ObjectCache.shared.getCachedUser(id: botUserID)?.user.firstName ?? String(localized: "this agent")
  }

  var body: some View {
    let defaultMode = store.defaultOutputMode(botUserID: botUserID)
    let threadMode = store.outputModeOverride(peer: peer, botUserID: botUserID)
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text("Output")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
        Spacer()
        if isUpdating {
          ProgressView().controlSize(.mini)
        }
      }

      row(
        title: "This thread",
        selection: threadMode.map(\.title) ?? String(localized: "Agent default — \(defaultMode.title)"),
        description: (threadMode ?? defaultMode).summary
      ) {
        Button {
          setThreadMode(nil)
        } label: {
          optionLabel(String(localized: "Agent default — \(defaultMode.title)"), isSelected: threadMode == nil)
        }
        Divider()
        ForEach(AgentThreadOutputMode.allCases, id: \.self) { mode in
          Button {
            setThreadMode(mode)
          } label: {
            optionLabel(mode.title, description: mode.summary, isSelected: threadMode == mode)
          }
        }
      }

      row(title: "Agent default", selection: defaultMode.title, description: nil) {
        ForEach(AgentThreadOutputMode.allCases, id: \.self) { mode in
          Button {
            setDefaultMode(mode)
          } label: {
            optionLabel(mode.title, description: mode.summary, isSelected: defaultMode == mode)
          }
        }
      }

      if !canConfigure {
        Label("Only \(ownerName) can change how \(botName) replies.", systemImage: "lock")
          .font(.caption2)
          .foregroundStyle(.tertiary)
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var ownerName: String {
    access.flatMap { ObjectCache.shared.getCachedUser(id: $0.ownerUserID)?.user.firstName }
      ?? String(localized: "the owner")
  }

  private func row<Options: View>(
    title: LocalizedStringResource,
    selection: String,
    description: String?,
    @ViewBuilder options: () -> Options
  ) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      HStack(spacing: 10) {
        Text(title)
          .font(.callout)
          .frame(maxWidth: .infinity, alignment: .leading)
        if canConfigure {
          Menu {
            options()
          } label: {
            Text(selection).lineLimit(1)
          }
          .menuStyle(.borderlessButton)
          .fixedSize()
          .disabled(isUpdating)
        } else {
          Text(selection).foregroundStyle(.secondary)
        }
      }
      if let description {
        Text(description)
          .font(.caption2)
          .foregroundStyle(.tertiary)
          .frame(maxWidth: .infinity, alignment: .trailing)
      }
    }
  }

  @ViewBuilder
  private func optionLabel(_ title: String, description: String? = nil, isSelected: Bool) -> some View {
    let content = VStack(alignment: .leading, spacing: 1) {
      Text(title)
      if let description {
        Text(description).font(.caption).foregroundStyle(.secondary)
      }
    }
    if isSelected {
      Label { content } icon: { Image(systemName: "checkmark") }
    } else {
      content
    }
  }

  private func setThreadMode(_ mode: AgentThreadOutputMode?) {
    let previous = store.outputModeOverride(peer: peer, botUserID: botUserID)
    store.setOutputModeOverride(mode, peer: peer, botUserID: botUserID)
    perform(revert: { store.setOutputModeOverride(previous, peer: peer, botUserID: botUserID) }) {
      let response = try await Api.realtime.callRpcDirect(
        method: .setAgentParticipation,
        input: .setAgentParticipation(.with {
          $0.peerID = peer.toInputPeer()
          $0.botUserID = botUserID
          // Unspecified clears the override back to the agent's default.
          $0.outputMode = mode?.protocolValue ?? .unspecified
        })
      )
      if case let .setAgentParticipation(result)? = response {
        store.apply(participation: result.participation)
      }
    }
  }

  private func setDefaultMode(_ mode: AgentThreadOutputMode) {
    let previous = store.defaultOutputMode(botUserID: botUserID)
    store.setDefaultOutputMode(mode, botUserID: botUserID)
    perform(revert: { store.setDefaultOutputMode(previous, botUserID: botUserID) }) {
      let response = try await Api.realtime.callRpcDirect(
        method: .updateAgentSettings,
        input: .updateAgentSettings(.with {
          $0.botUserID = botUserID
          $0.defaultOutputMode = mode.protocolValue
        })
      )
      if case let .updateAgentSettings(result)? = response {
        store.apply(runtime: result.runtime)
      }
    }
  }

  private func perform(revert: @escaping () -> Void, _ operation: @escaping () async throws -> Void) {
    guard !isUpdating else { return }
    isUpdating = true
    Task { @MainActor in
      defer { isUpdating = false }
      do {
        try await operation()
      } catch {
        revert()
        ToastCenter.shared.showError("Couldn’t change the output mode.")
      }
    }
  }
}

enum AgentOutputModeSettingsLoader {
  /// Loads the bot's runtime (agent default) and this chat's participations
  /// (thread override) when Agent Settings opens.
  @MainActor
  static func load(peer: InlineKit.Peer, botUserID: Int64) async {
    AgentGrantStore.shared.ensureLoaded(botUserID: botUserID)
    let store = AgentWorkStateStore.shared
    if case let .getAgentRuntime(result)? = try? await Api.realtime.callRpcDirect(
      method: .getAgentRuntime,
      input: .getAgentRuntime(.with { $0.botUserID = botUserID })
    ), result.hasRuntime {
      store.apply(runtime: result.runtime)
    }
    if case let .getAgentParticipations(result)? = try? await Api.realtime.callRpcDirect(
      method: .getAgentParticipations,
      input: .getAgentParticipations(.with { $0.peerID = peer.toInputPeer() })
    ) {
      result.participations.forEach { store.apply(participation: $0) }
    }
  }
}
