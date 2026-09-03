#if DEBUG || DEBUG_BUILD
import Foundation
import InlineCLIInstaller
import SwiftUI

struct DeveloperPlaygroundAgentSetupView: View {
  @State private var fixture = DeveloperAgentSetupFailureFixture.outdatedOpenClaw
  @State private var showsReplacementConfirmation = false

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 12) {
        VStack(alignment: .leading, spacing: 2) {
          Text("Agent Setup Errors")
            .font(.headline)
          Text("Deterministic failures rendered through the production setup screen.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        Spacer()

        Picker("Failure", selection: $fixture) {
          ForEach(DeveloperAgentSetupFailureFixture.allCases) { fixture in
            Text(verbatim: fixture.title)
              .tag(fixture)
          }
        }
        .labelsHidden()
        .frame(width: 220)
      }
      .padding(.horizontal, 20)
      .padding(.vertical, 12)

      Divider()

      AgentSetupFailureScreen(
        failure: fixture.failure,
        items: fixture.progressItems
      )

      if fixture.failure.supportsConfirmedReplacement {
        Divider()

        HStack {
          Spacer(minLength: 16)
          AgentSetupReplacementButton(
            presentation: fixture.failure.presentation,
            action: { showsReplacementConfirmation = true }
          )
          .buttonStyle(.bordered)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
      }
    }
    .agentSetupReplacementConfirmation(
      isPresented: $showsReplacementConfirmation,
      presentation: fixture.failure.presentation,
      onConfirm: { showsReplacementConfirmation = false }
    )
  }
}

private enum DeveloperAgentSetupFailureFixture: String, CaseIterable, Identifiable {
  case outdatedOpenClaw
  case brokenOpenClawPlugin
  case outdatedAmp
  case hermesAdapterUpdate
  case hermesCredentialConflict

  var id: Self { self }

  var title: String {
    switch self {
    case .outdatedOpenClaw:
      "OpenClaw needs an update"
    case .brokenOpenClawPlugin:
      "OpenClaw plugin could not load"
    case .outdatedAmp:
      "Amp needs an update"
    case .hermesAdapterUpdate:
      "Hermes adapter needs an update"
    case .hermesCredentialConflict:
      "Hermes found an existing connection"
    }
  }

  var failure: AgentSetupFailure {
    AgentSetupFailure(
      code: code,
      message: message,
      recoveryURL: URL(string: "https://inline.chat/docs/agents")!,
      failedPhase: "preflight"
    )
  }

  var progressItems: [AgentSetupProgressItem] {
    [
      AgentSetupProgressItem(id: .preflight, state: .failed),
      AgentSetupProgressItem(id: .bot),
      AgentSetupProgressItem(id: .integration),
      AgentSetupProgressItem(id: .access),
      AgentSetupProgressItem(id: .service),
      AgentSetupProgressItem(id: .verification),
    ]
  }

  private var code: String {
    switch self {
    case .outdatedOpenClaw, .brokenOpenClawPlugin:
      "plugin_probe_failed"
    case .outdatedAmp:
      "amp_cli_incompatible"
    case .hermesAdapterUpdate:
      "plugin_update_required"
    case .hermesCredentialConflict:
      "setup_conflict"
    }
  }

  private var message: String {
    switch self {
    case .outdatedOpenClaw:
      "Could not inspect the OpenClaw Inline plugin: Invalid config; error: unknown command 'inspect'"
    case .brokenOpenClawPlugin:
      "OpenClaw Inline plugin failed to load: Cannot find module '/local/plugin.js'"
    case .outdatedAmp:
      "The pinned Amp ACP adapter is incompatible with the installed Amp CLI."
    case .hermesAdapterUpdate:
      "The existing Hermes Inline bot identity was verified and will be preserved, but its legacy adapter must be updated."
    case .hermesCredentialConflict:
      "Hermes cannot verify whether an existing Inline credential needs to be preserved; install or update the Inline Hermes adapter, or rerun with --replace to explicitly allow replacement."
    }
  }
}
#endif
