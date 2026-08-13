import InlineCLIInstaller
import SwiftUI

struct AgentSetupWizardView: View {
  @Bindable var model: AgentSetupWizardModel
  @State private var showsReplacementConfirmation = false

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
    .alert(
      "Replace Existing Harness Setup?",
      isPresented: $showsReplacementConfirmation
    ) {
      Button("Replace and Retry", role: .destructive) {
        model.retryWithReplacement()
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(
        "This may replace the selected harness’s existing Inline plugin or credential and bot mapping. "
          + "It will not delete bots or change other harnesses. Continue?"
      )
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
    case .noHarnesses:
      noHarnesses
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
      Label(completionTitle, systemImage: "checkmark.circle.fill")
        .font(.title3.weight(.semibold))
        .foregroundStyle(.green)

      if let result = model.result {
        Text("\(result.bot.name) is connected through \(result.target) as @\(result.bot.username).")
          .fixedSize(horizontal: false, vertical: true)
        if !result.service.ready {
          Text("Configuration finished, but the service still needs to be restarted.")
            .foregroundStyle(.orange)
        }
        if model.isReady {
          Text("The bot chat is open. Send a first message to verify the full conversation path.")
            .foregroundStyle(.secondary)
        } else {
          Text("Finish the required service action, then retry setup to verify readiness before opening the bot.")
            .foregroundStyle(.secondary)
        }
      }
    }
  }

  private var completionTitle: String {
    guard model.result != nil else { return "Setup Complete" }
    return model.isReady ? "Agent Ready" : "Configuration Saved"
  }

  private var noHarnesses: some View {
    VStack(alignment: .leading, spacing: 14) {
      Label("No Supported Harnesses Found", systemImage: "terminal")
        .font(.title3.weight(.semibold))

      Text("Install one of these harnesses, then ask Inline to check again. Inline does not install third-party runtimes for you.")
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      ForEach(model.missingTargets) { target in
        Label(target.displayName, systemImage: "circle.dashed")
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
        if let failedPhase = failure.failedPhase {
          Text("Failed during: \(failedPhase)")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        if failure.isPartial {
          VStack(alignment: .leading, spacing: 4) {
            Text("Setup may have completed some work before the failure.")
              .font(.subheadline.weight(.medium))
            ForEach(failure.completedChanges, id: \.self) { change in
              Text("• \(change.replacingOccurrences(of: "_", with: " ").capitalized)")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
        }
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
      case .completed where model.isReady:
        Button("Set Up Another") {
          model.chooseAnotherHarness()
        }
        Button("Open Bot") {
          model.openBot()
        }
        .keyboardShortcut(.defaultAction)
      case .completed:
        Button("Set Up Another") {
          model.chooseAnotherHarness()
        }
        Button("Try Again") {
          model.start()
        }
        .keyboardShortcut(.defaultAction)
      case .noHarnesses:
        Button("Check Again") {
          model.start()
        }
        .keyboardShortcut(.defaultAction)
      case .failed:
        if model.canRepairSelectedSetup {
          Button("Repair Existing Setup…") {
            showsReplacementConfirmation = true
          }
        }
        Button("Try Again") {
          model.start()
        }
        .keyboardShortcut(.defaultAction)
      case .installingCLI, .signingIn, .discovering, .settingUp:
        Button(model.isCancelling ? "Cancelling…" : "Cancel") {
          model.cancelOperation()
        }
        .disabled(model.isCancelling)
      case .idle:
        Button("Start Setup") {
          model.start()
        }
        .keyboardShortcut(.defaultAction)
      }
    }
  }
}
