import InlineCLIInstaller
import SwiftUI

struct AgentSetupWizardView: View {
  @Bindable var model: AgentSetupWizardModel

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
        .padding(24)

      Divider()

      content
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(24)

      Divider()

      actions
        .padding(16)
    }
    .frame(minWidth: 560, minHeight: 460)
    .task {
      if model.phase == .idle {
        model.start()
      }
    }
  }

  private var header: some View {
    HStack(spacing: 14) {
      Image(systemName: "cpu")
        .font(.system(size: 28))
        .frame(width: 44, height: 44)
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 3) {
        Text("Set Up an Inline Agent")
          .font(.title2.weight(.semibold))
        Text("Inline installs its CLI, finds your local harnesses, and connects the one you choose.")
          .foregroundStyle(.secondary)
      }
    }
  }

  @ViewBuilder
  private var content: some View {
    switch model.phase {
    case .idle, .installingCLI:
      progress(
        title: "Preparing Inline CLI",
        detail: "Checking for a trusted CLI and installing or updating it when needed."
      )
    case .signingIn:
      progress(
        title: "Signing In",
        detail: "Giving the CLI its own revocable Inline session."
      )
    case .discovering:
      progress(
        title: "Finding Agent Harnesses",
        detail: "Looking for supported harnesses already installed on this Mac."
      )
    case .choosing:
      harnessPicker
    case let .settingUp(name):
      progress(
        title: "Setting Up \(name)",
        detail: "Creating or reusing a bot, installing Inline support, starting the service, and verifying the connection."
      )
    case .completed:
      completion
    case .failed:
      failure
    }
  }

  private func progress(title: String, detail: String) -> some View {
    HStack(alignment: .top, spacing: 14) {
      ProgressView()
        .controlSize(.regular)
      VStack(alignment: .leading, spacing: 5) {
        Text(title)
          .font(.headline)
        Text(detail)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
  }

  private var harnessPicker: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Choose an installed harness")
        .font(.headline)
      Text("Inline will configure only the harness you select. You can return later to connect another one.")
        .foregroundStyle(.secondary)

      List(model.installedTargets, selection: $model.selectedTargetID) { target in
        HStack(spacing: 12) {
          Image(systemName: target.family == .gateway ? "network" : "terminal")
            .frame(width: 22)
            .accessibilityHidden(true)
          VStack(alignment: .leading, spacing: 2) {
            Text(target.displayName)
            Text(target.family == .gateway ? "Gateway integration" : "Local coding harness")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
        .tag(target.id)
        .padding(.vertical, 4)
      }
      .frame(minHeight: 150)

      if !model.missingTargets.isEmpty {
        Text("Not installed: \(model.missingTargets.map(\.displayName).joined(separator: ", "))")
          .font(.caption)
          .foregroundStyle(.tertiary)
      }
    }
  }

  private var completion: some View {
    VStack(alignment: .leading, spacing: 14) {
      Label("Agent Ready", systemImage: "checkmark.circle.fill")
        .font(.title3.weight(.semibold))
        .foregroundStyle(.green)

      if let result = model.result {
        Text("\(result.bot.name) is connected through \(result.target) as @\(result.bot.username).")
          .fixedSize(horizontal: false, vertical: true)
        if !result.service.ready {
          Text("Configuration finished, but the service still needs to be restarted.")
            .foregroundStyle(.orange)
        }
        Text("Open the bot chat to send a first message and verify the full conversation path.")
          .foregroundStyle(.secondary)
      }
    }
  }

  private var failure: some View {
    VStack(alignment: .leading, spacing: 12) {
      Label("Setup Couldn’t Finish", systemImage: "exclamationmark.triangle.fill")
        .font(.title3.weight(.semibold))
        .foregroundStyle(.orange)

      if let failure = model.failure {
        Text(failure.message)
          .fixedSize(horizontal: false, vertical: true)
        Text("Error code: \(failure.code)")
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
        if let suggestion = failure.recoverySuggestion {
          Text(suggestion)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
  }

  @ViewBuilder
  private var actions: some View {
    HStack(spacing: 10) {
      Link("Setup Guide", destination: model.documentationURL)

      Spacer()

      switch model.phase {
      case .choosing:
        Button("Set Up Selected Harness") {
          model.setUpSelectedTarget()
        }
        .keyboardShortcut(.defaultAction)
        .disabled(model.selectedTarget == nil)
      case .completed:
        Button("Set Up Another") {
          model.chooseAnotherHarness()
        }
        Button("Open Bot") {
          model.openBot()
        }
        .keyboardShortcut(.defaultAction)
      case .failed:
        Button("Try Again") {
          model.start()
        }
        .keyboardShortcut(.defaultAction)
      case .settingUp:
        Button(model.isCancelling ? "Cancelling…" : "Cancel") {
          model.cancelSetup()
        }
        .disabled(model.isCancelling)
      case .idle, .installingCLI, .signingIn, .discovering:
        Text("This may take a minute.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }
}
