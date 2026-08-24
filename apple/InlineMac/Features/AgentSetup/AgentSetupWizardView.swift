import AppKit
import InlineCLIInstaller
import SwiftUI

struct AgentSetupWizardView: View {
  @Bindable var model: AgentSetupWizardModel
  @State private var showsReplacementConfirmation = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
        .padding(.horizontal, 32)
        .padding(.top, 28)
        .padding(.bottom, 22)

      Divider()

      content
        .frame(maxWidth: 480, maxHeight: .infinity, alignment: .top)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.horizontal, 32)
        .padding(.vertical, 28)

      Divider()

      actions
        .buttonStyle(.bordered)
        .controlSize(.large)
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }
    .frame(minWidth: 560, minHeight: 460)
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
    VStack(spacing: 10) {
      Image(systemName: "cpu")
        .font(.system(size: 30, weight: .medium))
        .frame(width: 52, height: 52)
        .accessibilityHidden(true)

      VStack(spacing: 5) {
        Text("Set Up an Inline Agent")
          .font(.title2.weight(.semibold))
        Text("Connect an agent on this Mac or hand setup off to another machine.")
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
      }
    }
    .frame(maxWidth: .infinity)
  }

  @ViewBuilder
  private var content: some View {
    switch model.phase {
    case .choosingLocation:
      machinePicker
    case .remoteSetup:
      remoteSetup
    case .idle:
      machinePicker
    case .installingCLI:
      progress(
        title: "Checking Inline CLI",
        detail: "Reusing a compatible Inline CLI when one is already installed, or installing the version setup needs."
      )
    case .signingIn:
      progress(
        title: "Checking CLI Access",
        detail: "Keeping an existing sign-in when it matches this account, or creating a separate revocable CLI session when needed."
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
    VStack(spacing: 14) {
      ProgressView()
        .controlSize(.regular)
      VStack(spacing: 6) {
        Text(title)
          .font(.headline)
        Text(detail)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: 380)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
  }

  private var machinePicker: some View {
    VStack(spacing: 20) {
      VStack(spacing: 6) {
        Text("Where is your agent running?")
          .font(.headline)
        Text("Choose this Mac for a local setup, or another machine for servers, cloud hosts, and other computers.")
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
      }

      VStack(spacing: 12) {
        AgentSetupChoiceButton(
          title: "This Mac",
          description: "Set up an agent or harness installed on this Mac.",
          systemImage: "laptopcomputer",
          action: model.chooseLocalSetup
        )
        AgentSetupChoiceButton(
          title: "Another Machine",
          description: "Continue setup on a server, cloud host, or another computer.",
          systemImage: "server.rack",
          action: model.chooseRemoteSetup
        )
      }
    }
  }

  private var remoteSetup: some View {
    VStack(spacing: 20) {
      VStack(spacing: 6) {
        Text("Continue on the other machine")
          .font(.headline)
        Text("Let the agent handle setup there, or follow the guide yourself.")
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
      }

      VStack(spacing: 12) {
        AgentSetupChoiceButton(
          title: "Copy Prompt for Agent",
          description: "Paste one instruction into the agent running on that machine.",
          systemImage: "doc.on.doc"
        ) {
          let pasteboard = NSPasteboard.general
          pasteboard.clearContents()
          pasteboard.setString(model.remoteSetupPrompt, forType: .string)
          ToastCenter.shared.showSuccess("Copied setup prompt")
        }

        Link(destination: model.documentationURL) {
          AgentSetupChoiceLabel(
            title: "Read Setup Guide",
            description: "Open the instructions and set up your agent manually.",
            systemImage: "book.pages"
          )
        }
        .buttonStyle(.plain)
      }

      Text(model.remoteSetupPrompt)
        .font(.caption.monospaced())
        .foregroundStyle(.tertiary)
        .textSelection(.enabled)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: 420)
    }
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
      Label(completionTitle, systemImage: completionSystemImage)
        .font(.title3.weight(.semibold))
        .foregroundStyle(completionColor)

      if let result = model.result {
        Text(completionSummary(for: result))
          .fixedSize(horizontal: false, vertical: true)
        if !result.service.ready {
          Text("Configuration finished, but the service still needs to be restarted.")
            .foregroundStyle(.orange)
        } else if let readiness = result.readiness, !readiness.ready {
          if let message = readiness.message {
            Text(message)
              .foregroundStyle(.orange)
              .fixedSize(horizontal: false, vertical: true)
          } else {
            Text("Hermes is connected to Inline, but another setup step is required.")
              .foregroundStyle(.orange)
              .fixedSize(horizontal: false, vertical: true)
          }
          if let command = readiness.command {
            Text("Run this command in Terminal, then check again:")
              .foregroundStyle(.secondary)
            Text(command)
              .font(.body.monospaced())
              .textSelection(.enabled)
          }
        }
        if model.isReady {
          Text("The bot chat is open. Send a first message to verify the full conversation path.")
            .foregroundStyle(.secondary)
        } else if result.service.ready, result.readiness?.ready == false {
          Text("After completing that step, check again to verify readiness and open the bot.")
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
    if model.isReady { return "Agent Ready" }
    if model.result?.service.ready == true {
      switch model.result?.readiness?.code {
      case "provider_configuration_required":
        return "Provider Setup Required"
      case "provider_readiness_unknown":
        return "Provider Check Required"
      case "inline_adapter_not_ready":
        return "Inline Connection Required"
      case "inline_adapter_status_unsupported":
        return "Hermes Update Required"
      case "inline_adapter_readiness_unknown":
        return "Readiness Check Required"
      default:
        break
      }
    }
    return "Configuration Saved"
  }

  private func completionSummary(for result: AgentSetupResult) -> String {
    let readinessCode = result.readiness?.code
    let adapterUnavailable = readinessCode == "inline_adapter_not_ready"
      || readinessCode == "inline_adapter_status_unsupported"
      || readinessCode == "inline_adapter_readiness_unknown"
    let state = result.service.ready && !adapterUnavailable ? "connected through" : "configured for"
    return "\(result.bot.name) is \(state) \(result.target) as @\(result.bot.username)."
  }

  private var completionSystemImage: String {
    model.isReady ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
  }

  private var completionColor: Color {
    model.isReady ? .green : .orange
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
      switch model.phase {
      case .choosingLocation, .idle:
        Link("Setup Guide", destination: model.documentationURL)
        Spacer()
      case .remoteSetup:
        Button("Back") {
          model.returnToLocationChoice()
        }
        Spacer()
      case .choosing:
        Link("Setup Guide", destination: model.documentationURL)
        Spacer()
        Button("Set Up Selected Harness") {
          model.setUpSelectedTarget()
        }
        .keyboardShortcut(.defaultAction)
        .disabled(model.selectedTarget == nil)
      case .completed where model.isReady:
        Link("Setup Guide", destination: model.documentationURL)
        Spacer()
        Button("Set Up Another") {
          model.chooseAnotherHarness()
        }
        Button("Open Bot") {
          model.openBot()
        }
        .keyboardShortcut(.defaultAction)
      case .completed:
        Link("Setup Guide", destination: model.documentationURL)
        Spacer()
        Button("Set Up Another") {
          model.chooseAnotherHarness()
        }
        if model.result?.service.ready == true, model.result?.readiness?.ready == false {
          Button("Check Again") {
            model.setUpSelectedTarget()
          }
          .keyboardShortcut(.defaultAction)
        } else {
          Button("Try Again") {
            model.start()
          }
          .keyboardShortcut(.defaultAction)
        }
      case .noHarnesses:
        Link("Setup Guide", destination: model.documentationURL)
        Spacer()
        Button("Check Again") {
          model.start()
        }
        .keyboardShortcut(.defaultAction)
      case .failed:
        Link("Setup Guide", destination: model.documentationURL)
        Spacer()
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
        Link("Setup Guide", destination: model.documentationURL)
        Spacer()
        Button(model.isCancelling ? "Cancelling…" : "Cancel") {
          model.cancelOperation()
        }
        .disabled(model.isCancelling)
      }
    }
  }
}

private struct AgentSetupChoiceButton: View {
  let title: LocalizedStringResource
  let description: LocalizedStringResource
  let systemImage: String
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      AgentSetupChoiceLabel(
        title: title,
        description: description,
        systemImage: systemImage
      )
    }
    .buttonStyle(.plain)
  }
}

private struct AgentSetupChoiceLabel: View {
  let title: LocalizedStringResource
  let description: LocalizedStringResource
  let systemImage: String

  var body: some View {
    HStack(spacing: 14) {
      Image(systemName: systemImage)
        .font(.system(size: 20))
        .foregroundStyle(.secondary)
        .frame(width: 28)
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 3) {
        Text(title)
          .font(.body.weight(.medium))
        Text(description)
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      Image(systemName: "chevron.right")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.tertiary)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .accessibilityHidden(true)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    .overlay {
      RoundedRectangle(cornerRadius: 10)
        .stroke(Color(nsColor: .separatorColor).opacity(0.65), lineWidth: 1)
    }
    .contentShape(Rectangle())
  }
}
