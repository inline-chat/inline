import Foundation
import InlineProtocol

/// Output mode from Agent Settings: the agent-wide default and per-thread
/// overrides. Changes apply optimistically and revert when the server rejects them.
public extension AgentWorkStateStore {
  /// Refreshes the bot's runtime and default. The cached values render meanwhile.
  func loadAgentSettings(botUserID: Int64) async {
    guard botUserID > 0 else { return }
    // The runtime also carries status, and mirrors the default for servers
    // without the settings read.
    if case let .getAgentRuntime(result)? = try? await Api.realtime.callRpcDirect(
      method: .getAgentRuntime,
      input: .getAgentRuntime(.with { $0.botUserID = botUserID })
    ), result.hasRuntime {
      apply(runtime: result.runtime)
    }
    // Settings exist for every owned bot and win over the mirror.
    if case let .getAgentSettings(result)? = try? await Api.realtime.callRpcDirect(
      method: .getAgentSettings,
      input: .getAgentSettings(.with { $0.botUserID = botUserID })
    ), result.hasSettings {
      apply(settings: result.settings, botUserID: botUserID)
    }
  }

  /// The bot's default and this chat's override, for a chat's Agent Settings.
  func loadOutputModes(peer: Peer, botUserID: Int64) async {
    await loadAgentSettings(botUserID: botUserID)
    if case let .getAgentParticipations(result)? = try? await Api.realtime.callRpcDirect(
      method: .getAgentParticipations,
      input: .getAgentParticipations(.with { $0.peerID = peer.toInputPeer() })
    ) {
      result.participations.forEach { apply(participation: $0) }
    }
  }

  func updateDefaultOutputMode(_ mode: AgentThreadOutputMode, botUserID: Int64) async throws {
    let previous = defaultOutputMode(botUserID: botUserID)
    setDefaultOutputMode(mode, botUserID: botUserID)
    do {
      let response = try await Api.realtime.callRpcDirect(
        method: .updateAgentSettings,
        input: .updateAgentSettings(.with {
          $0.botUserID = botUserID
          $0.defaultOutputMode = mode.protocolValue
        })
      )
      guard case let .updateAgentSettings(result)? = response else { return }
      if result.hasSettings {
        apply(settings: result.settings, botUserID: botUserID)
      } else if result.hasRuntime {
        apply(runtime: result.runtime)
      }
    } catch {
      setDefaultOutputMode(previous, botUserID: botUserID)
      throw error
    }
  }

  /// Nil clears the thread's override back to the agent's default.
  func updateOutputModeOverride(_ mode: AgentThreadOutputMode?, peer: Peer, botUserID: Int64) async throws {
    let previous = outputModeOverride(peer: peer, botUserID: botUserID)
    setOutputModeOverride(mode, peer: peer, botUserID: botUserID)
    do {
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
        apply(participation: result.participation)
      }
    } catch {
      setOutputModeOverride(previous, peer: peer, botUserID: botUserID)
      throw error
    }
  }

  private func apply(settings: InlineProtocol.AgentSettings, botUserID: Int64) {
    // Unspecified means Detailed.
    let mode = AgentThreadOutputMode(settings.defaultOutputMode) ?? .detailed
    if defaultOutputMode(botUserID: botUserID) != mode {
      setDefaultOutputMode(mode, botUserID: botUserID)
    }
  }
}
