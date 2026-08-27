import AppKit
import InlineCLIInstaller
import SwiftUI

struct AgentSetupWizardToolbar: ToolbarContent {
  let canGoBack: Bool
  let documentationURL: URL
  let onBack: () -> Void

  var body: some ToolbarContent {
    if canGoBack {
      ToolbarItem(placement: .navigation) {
        Button("Back", systemImage: "chevron.left", action: onBack)
          .labelStyle(.iconOnly)
          .keyboardShortcut("[", modifiers: .command)
          .help("Back")
      }
    }

    ToolbarItem(placement: .primaryAction) {
      Button("Open Agent Setup Guide", systemImage: "questionmark") {
        _ = NSWorkspace.shared.open(documentationURL)
      }
      .labelStyle(.iconOnly)
      .help("Open Agent Setup Guide")
    }
  }
}

struct AgentSetupWizardContentView: View {
  @Bindable var model: AgentSetupWizardModel

  var body: some View {
    switch model.phase {
    case .idle, .choosingLocation:
      AgentSetupLocationScreen(
        onChooseLocal: model.chooseLocalSetup,
        onChooseRemote: model.chooseRemoteSetup
      )
    case .remoteSetup:
      AgentSetupRemoteScreen(
        prompt: model.remoteSetupPrompt,
        documentationURL: model.documentationURL
      )
    case .installingCLI, .signingIn, .discovering:
      AgentSetupProgressScreen(
        title: "Preparing This Mac",
        detail: model.phase.preparationDetail,
        items: model.progressItems
      )
    case .choosing:
      AgentSetupHarnessPickerScreen(
        installedTargets: model.installedTargets,
        missingTargets: model.missingTargets,
        selectedTargetID: $model.selectedTargetID
      )
    case .noHarnesses:
      AgentSetupNoHarnessesScreen(targets: model.missingTargets)
    case let .settingUp(name):
      AgentSetupProgressScreen(
        title: "Setting Up \(name)",
        detail: "Completed work stays visible. If setup pauses or fails, the active step shows where to look.",
        items: model.progressItems
      )
    case .completed:
      AgentSetupCompletionScreen(
        result: model.result,
        isReady: model.isReady,
        items: model.progressItems
      )
    case .failed:
      AgentSetupFailureScreen(
        failure: model.failure,
        items: model.progressItems
      )
    }
  }
}

struct AgentSetupWizardFooter: View {
  @Bindable var model: AgentSetupWizardModel
  let onRepair: () -> Void

  var body: some View {
    HStack(spacing: 10) {
      Spacer(minLength: 16)

      switch model.phase {
      case .choosing:
        Button("Set Up Agent") {
          model.setUpSelectedTarget()
        }
        .keyboardShortcut(.defaultAction)
        .disabled(model.selectedTarget == nil)
        .buttonStyle(.borderedProminent)
      case .completed where model.isReady:
        Button("Set Up Another") {
          model.chooseAnotherHarness()
        }
        Button("Open Agent") {
          model.openBot()
        }
        .keyboardShortcut(.defaultAction)
        .buttonStyle(.borderedProminent)
      case .completed:
        Button("Set Up Another") {
          model.chooseAnotherHarness()
        }
        Button("Check Again") {
          model.setUpSelectedTarget()
        }
        .keyboardShortcut(.defaultAction)
        .buttonStyle(.borderedProminent)
      case .noHarnesses:
        Button("Check Again") {
          model.start()
        }
        .keyboardShortcut(.defaultAction)
        .buttonStyle(.borderedProminent)
      case .failed:
        if model.canRepairSelectedSetup {
          Button("Repair Existing Setup…", action: onRepair)
        } else if model.canRetryFailure {
          if model.failureOperation == .targetSetup {
            Button("Retry Setup") {
              model.retryFailure()
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
          } else {
            Button("Try Again") {
              model.retryFailure()
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
          }
        }
      case .installingCLI, .signingIn, .discovering, .settingUp:
        Button(model.isCancelling ? "Cancelling…" : "Cancel") {
          model.cancelOperation()
        }
        .disabled(model.isCancelling)
        .keyboardShortcut(.cancelAction)
      case .idle, .choosingLocation, .remoteSetup:
        EmptyView()
      }
    }
    .buttonStyle(.bordered)
    .controlSize(.regular)
    .frame(minHeight: 24)
    .padding(.horizontal, 20)
    .padding(.vertical, 10)
  }
}

private struct AgentSetupLocationScreen: View {
  let onChooseLocal: () -> Void
  let onChooseRemote: () -> Void

  var body: some View {
    VStack(spacing: 0) {
      AgentSetupScreenHeader(
        systemImage: "cpu",
        title: "Where Is Your Agent Running?",
        detail: "Choose the Mac or other machine that already has the agent or harness."
      )

      List {
        Button(action: onChooseLocal) {
          AgentSetupNavigationRow(
            systemImage: "laptopcomputer",
            title: "This Mac",
            detail: "Use an agent or harness installed on this Mac."
          )
        }
        Button(action: onChooseRemote) {
          AgentSetupNavigationRow(
            systemImage: "server.rack",
            title: "Another Machine",
            detail: "Continue on a server, cloud host, or another computer."
          )
        }
      }
      .buttonStyle(.plain)
      .listStyle(.inset)
      .scrollContentBackground(.hidden)
    }
  }
}

private struct AgentSetupRemoteScreen: View {
  let prompt: String
  let documentationURL: URL
  @State private var copied = false

  var body: some View {
    VStack(spacing: 0) {
      AgentSetupScreenHeader(
        systemImage: "arrow.up.right.square",
        title: "Continue on the Other Machine",
        detail: "Give the setup instruction to the agent there, or follow the guide yourself."
      )

      List {
        Button(action: copyPrompt) {
          AgentSetupNavigationRow(
            systemImage: copied ? "checkmark" : "doc.on.doc",
            title: copied ? "Prompt Copied" : "Copy Prompt for Agent",
            detail: "Paste one instruction into the agent running on that machine.",
            showsDisclosure: false
          )
        }
        .buttonStyle(.plain)

        Link(destination: documentationURL) {
          AgentSetupNavigationRow(
            systemImage: "book.pages",
            title: "Read Setup Guide",
            detail: "Open the instructions and set up the agent manually."
          )
        }
        .buttonStyle(.plain)

        DisclosureGroup {
          Text(prompt)
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .padding(.vertical, 8)
        } label: {
          Label("Setup Prompt", systemImage: "text.quote")
            .font(.body.weight(.medium))
        }
      }
      .listStyle(.inset)
      .scrollContentBackground(.hidden)
    }
  }

  private func copyPrompt() {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(prompt, forType: .string)
    copied = true
    ToastCenter.shared.showSuccess("Copied setup prompt")
  }
}

private struct AgentSetupHarnessPickerScreen: View {
  let installedTargets: [AgentHarnessTarget]
  let missingTargets: [AgentHarnessTarget]
  @Binding var selectedTargetID: String?

  var body: some View {
    VStack(spacing: 0) {
      AgentSetupScreenHeader(
        systemImage: "square.stack.3d.up",
        title: "Choose an Agent Harness",
        detail: "Inline configures only the selected installed harness."
      )

      List(installedTargets, selection: $selectedTargetID) { target in
        AgentSetupHarnessRow(target: target)
          .tag(target.id)
      }
      .listStyle(.inset)
      .scrollContentBackground(.hidden)

      if !missingTargets.isEmpty {
        Text("Not installed: \(missingTargets.map(\.displayName).formatted())")
          .font(.caption)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 24)
          .padding(.bottom, 12)
      }
    }
  }
}

private struct AgentSetupHarnessRow: View {
  let target: AgentHarnessTarget

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: target.family == .gateway ? "network" : "terminal")
        .frame(width: 24)
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(target.displayName)
        Text(target.family == .gateway ? "Gateway integration" : "Local coding harness")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.vertical, 5)
  }
}

private struct AgentSetupNoHarnessesScreen: View {
  let targets: [AgentHarnessTarget]

  var body: some View {
    ScrollView {
      VStack(spacing: 20) {
        ContentUnavailableView {
          Label("No Supported Harnesses", systemImage: "terminal")
        } description: {
          Text(
            "Install a supported harness, then check again. Inline does not install third-party runtimes."
          )
        }

        if !targets.isEmpty {
          GroupBox {
            VStack(alignment: .leading, spacing: 10) {
              ForEach(targets) { target in
                Label(target.displayName, systemImage: "circle.dashed")
                  .foregroundStyle(.secondary)
              }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
          } label: {
            Text("Supported Harnesses")
          }
        }
      }
      .frame(maxWidth: 440)
      .frame(maxWidth: .infinity)
      .padding(.horizontal, 32)
      .padding(.vertical, 24)
    }
  }
}

private struct AgentSetupProgressScreen: View {
  let title: LocalizedStringResource
  let detail: LocalizedStringResource
  let items: [AgentSetupProgressItem]

  var body: some View {
    ScrollView {
      VStack(spacing: 22) {
        AgentSetupScreenHeader(
          systemImage: "gearshape.2",
          title: title,
          detail: detail
        )
        AgentSetupProgressList(items: items)
          .padding(.horizontal, 32)
          .padding(.bottom, 24)
      }
      .frame(maxWidth: 500)
      .frame(maxWidth: .infinity)
    }
  }
}

private struct AgentSetupProgressList: View {
  let items: [AgentSetupProgressItem]

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      if let currentStep {
        Text("Step \(currentStep) of \(items.count)")
          .font(.caption.weight(.medium))
          .foregroundStyle(.secondary)
      }

      GroupBox {
        VStack(spacing: 0) {
          ForEach(items) { item in
            AgentSetupProgressRow(item: item)
            if item.id != items.last?.id {
              Divider()
                .padding(.leading, 34)
            }
          }
        }
      }
    }
  }

  private var currentStep: Int? {
    if let current = items.firstIndex(where: {
      switch $0.state {
      case .active, .failed: true
      case .pending, .completed: false
      }
    }) {
      return current + 1
    }
    let completed = items.count(where: {
      if case .completed = $0.state { return true }
      return false
    })
    return completed == 0 ? nil : min(completed, items.count)
  }
}

private struct AgentSetupProgressRow: View {
  let item: AgentSetupProgressItem

  var body: some View {
    HStack(spacing: 12) {
      statusSymbol
        .frame(width: 22, height: 22)
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 2) {
        Text(item.id.title)
          .foregroundStyle(titleStyle)
        statusDetail
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.horizontal, 4)
    .padding(.vertical, 8)
    .accessibilityElement(children: .combine)
  }

  @ViewBuilder
  private var statusSymbol: some View {
    switch item.state {
    case .pending:
      Image(systemName: "circle")
        .foregroundStyle(.tertiary)
    case .active:
      ProgressView()
        .controlSize(.small)
    case .completed:
      Image(systemName: "checkmark.circle.fill")
        .foregroundStyle(.green)
    case .failed:
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(.orange)
    }
  }

  @ViewBuilder
  private var statusDetail: some View {
    switch item.state {
    case .pending:
      Text("Waiting")
    case let .active(startedAt):
      HStack(spacing: 4) {
        Text("Elapsed")
        Text(startedAt, style: .timer)
          .monospacedDigit()
      }
    case let .completed(outcome):
      Text(outcome?.label ?? "Completed")
    case .failed:
      Text("Stopped here")
    }
  }

  private var titleStyle: HierarchicalShapeStyle {
    if case .pending = item.state { return .secondary }
    return .primary
  }
}

private struct AgentSetupCompletionScreen: View {
  let result: AgentSetupResult?
  let isReady: Bool
  let items: [AgentSetupProgressItem]

  var body: some View {
    ScrollView {
      VStack(spacing: 18) {
        AgentSetupScreenHeader(
          systemImage: isReady ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
          title: title,
          detail: summary
        )

        VStack(alignment: .leading, spacing: 16) {
          AgentSetupProgressList(items: items)

          if let readiness = result?.readiness, !readiness.ready {
            AgentSetupRecoveryCard(readiness: readiness)
          } else if result?.service.ready == false {
            Label(
              "The configuration was saved, but the managed service still needs to start.",
              systemImage: "exclamationmark.triangle"
            )
            .foregroundStyle(.secondary)
          } else if isReady {
            Label(
              "Open the agent and send a first message to verify the full conversation path.",
              systemImage: "bubble.left"
            )
            .foregroundStyle(.secondary)
          }
        }
        .padding(.horizontal, 32)
        .padding(.bottom, 24)
      }
      .frame(maxWidth: 500)
      .frame(maxWidth: .infinity)
    }
  }

  private var title: LocalizedStringResource {
    guard let result else { return "Setup Complete" }
    if isReady { return "Agent Ready" }
    if result.service.ready, result.readiness?.code == "provider_configuration_required" {
      return "Provider Setup Required"
    }
    if result.service.ready { return "One More Step Required" }
    return "Configuration Saved"
  }

  private var summary: LocalizedStringResource {
    guard let result else { return "Inline finished the available setup work." }
    if isReady {
      return "\(result.bot.name) is connected through \(result.target) as @\(result.bot.username)."
    }
    return "\(result.bot.name) is configured through \(result.target) as @\(result.bot.username)."
  }
}

private struct AgentSetupRecoveryCard: View {
  let readiness: AgentSetupResult.Readiness

  var body: some View {
    GroupBox {
      VStack(alignment: .leading, spacing: 8) {
        if let message = readiness.message {
          Text(message)
        }
        if let command = readiness.command {
          Text("Run this command in Terminal, then check again:")
            .foregroundStyle(.secondary)
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(command)
              .font(.callout.monospaced())
              .textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
            Button("Copy Command", systemImage: "doc.on.doc") {
              copyCommand(command)
            }
            .labelStyle(.iconOnly)
            .help("Copy Command")
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    } label: {
      Label {
        Text("Action Required")
      } icon: {
        Image(systemName: "exclamationmark.triangle.fill")
          .foregroundStyle(.orange)
      }
    }
  }

  private func copyCommand(_ command: String) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(command, forType: .string)
    ToastCenter.shared.showSuccess("Copied command")
  }
}

private struct AgentSetupFailureScreen: View {
  let failure: AgentSetupFailure?
  let items: [AgentSetupProgressItem]
  @State private var showsDetails = false

  var body: some View {
    ScrollView {
      VStack(spacing: 18) {
        AgentSetupScreenHeader(
          systemImage: "exclamationmark.triangle.fill",
          title: "Setup Couldn’t Finish",
          detail: "Inline kept completed steps and the diagnostic information needed to recover."
        )

        VStack(alignment: .leading, spacing: 16) {
          if let message = failure?.message {
            GroupBox {
              Text(message)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
              Label("What Happened", systemImage: "exclamationmark.circle")
            }
          }

          if !items.isEmpty {
            AgentSetupProgressList(items: items)
          }

          if let failure {
            DisclosureGroup("Technical Details", isExpanded: $showsDetails) {
              AgentSetupFailureDetails(failure: failure)
                .padding(.top, 8)
            }
          }
        }
        .padding(.horizontal, 32)
        .padding(.bottom, 24)
      }
      .frame(maxWidth: 500)
      .frame(maxWidth: .infinity)
    }
  }
}

private struct AgentSetupFailureDetails: View {
  let failure: AgentSetupFailure
  @State private var copiedDiagnostics = false

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Error code: \(failure.code)")
        .font(.caption.monospaced())
      if let failedPhase = failure.failedPhase {
        Text("Failed during: \(failedPhase)")
          .font(.caption)
      }
      if failure.isPartial {
        Text("Some setup work completed before the failure.")
          .font(.subheadline.weight(.medium))
        ForEach(failure.completedChanges, id: \.self) { change in
          Text("• \(change.replacingOccurrences(of: "_", with: " ").capitalized)")
            .font(.caption)
        }
      }
      if let suggestion = failure.recoverySuggestion {
        Text(suggestion)
          .textSelection(.enabled)
      }
      Button {
        copyDiagnosticSummary()
      } label: {
        if copiedDiagnostics {
          Label("Diagnostic Summary Copied", systemImage: "checkmark")
        } else {
          Label("Copy Diagnostic Summary", systemImage: "doc.on.doc")
        }
      }
      .buttonStyle(.bordered)
      .foregroundStyle(.primary)
    }
    .foregroundStyle(.secondary)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func copyDiagnosticSummary() {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(diagnosticSummary, forType: .string)
    copiedDiagnostics = true
  }

  private var diagnosticSummary: String {
    var lines = [
      "Inline agent setup could not finish.",
      "Error code: \(failure.code)",
      "Message: \(failure.message)",
    ]
    if let failedPhase = failure.failedPhase {
      lines.append("Failed phase: \(failedPhase)")
    }
    if !failure.completedChanges.isEmpty {
      lines.append("Completed changes: \(failure.completedChanges.joined(separator: ", "))")
    }
    if let suggestion = failure.recoverySuggestion {
      lines.append("Suggested recovery: \(suggestion)")
    }
    return lines.joined(separator: "\n")
  }
}

private struct AgentSetupScreenHeader: View {
  let systemImage: String
  let title: LocalizedStringResource
  let detail: LocalizedStringResource

  var body: some View {
    VStack(spacing: 8) {
      Image(systemName: systemImage)
        .font(.title3.weight(.medium))
        .frame(width: 28, height: 28)
        .accessibilityHidden(true)
      Text(title)
        .font(.title3.weight(.semibold))
      Text(detail)
        .font(.callout)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: 440)
    .frame(maxWidth: .infinity)
    .padding(.horizontal, 24)
    .padding(.top, 20)
    .padding(.bottom, 14)
  }
}

private struct AgentSetupNavigationRow: View {
  let systemImage: String
  let title: LocalizedStringResource
  let detail: LocalizedStringResource
  var showsDisclosure = true

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: systemImage)
        .font(.title3)
        .foregroundStyle(.secondary)
        .frame(width: 26)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.body.weight(.medium))
        Text(detail)
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      if showsDisclosure {
        Image(systemName: "chevron.right")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.tertiary)
          .accessibilityHidden(true)
      }
    }
    .padding(.vertical, 7)
    .contentShape(Rectangle())
  }
}

private extension AgentSetupWizardModel.Phase {
  var preparationDetail: LocalizedStringResource {
    switch self {
    case .installingCLI:
      "Inline checks the CLI, access, and installed agent harnesses before changing anything."
    case .signingIn:
      "Inline is securely connecting the CLI to your signed-in account."
    case .discovering:
      "Inline is finding supported harnesses already installed on this Mac."
    case .idle, .choosingLocation, .remoteSetup, .choosing, .noHarnesses, .settingUp,
         .completed, .failed:
      "Inline is preparing this Mac for agent setup."
    }
  }
}

private extension AgentSetupProgressItem.ID {
  var title: LocalizedStringResource {
    switch self {
    case .cli: "Prepare Inline CLI"
    case .authentication: "Check CLI Access"
    case .discovery: "Find Installed Harnesses"
    case .preflight: "Inspect Existing Setup"
    case .bot: "Create or Reuse Bot"
    case .integration: "Configure Inline Integration"
    case .access: "Set Agent Access"
    case .service: "Start Managed Service"
    case .verification: "Verify Readiness"
    case .configuration: "Configure Agent"
    }
  }
}

private extension AgentSetupProgressItem.Outcome {
  var label: LocalizedStringResource {
    switch self {
    case .ready:
      "Ready"
    case .authenticated:
      "Access is ready"
    case let .found(count):
      "Found \(count)"
    case let .cli(code):
      switch code {
      case "created": "Created"
      case "reused", "kept": "Reused existing setup"
      case "configured": "Configured"
      case "installed": "Installed"
      case "updated": "Updated"
      case "repaired": "Repaired"
      case "replaced": "Replaced"
      case "started": "Started"
      case "restarted": "Restarted"
      case "ready": "Ready"
      case "skipped": "Skipped"
      case "action_required": "Action required"
      default: "Completed"
      }
    }
  }
}
