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
        targetID: nil,
        startedAt: model.operationStartedAt,
        items: model.progressItems
      )
    case .choosing:
      AgentSetupHarnessPickerScreen(
        installedTargets: model.installedTargets,
        missingTargets: model.missingTargets,
        selectedTargetID: $model.selectedTargetID,
        documentationURL: model.documentationURL,
        agentInstructionsURL: model.agentInstructionsURL
      )
    case .noHarnesses:
      AgentSetupNoHarnessesScreen(targets: model.missingTargets)
    case let .settingUp(name):
      AgentSetupProgressScreen(
        title: "Setting Up \(name)",
        targetID: model.selectedTargetID,
        startedAt: model.operationStartedAt,
        items: model.progressItems
      )
    case .completed:
      AgentSetupCompletionScreen(
        result: model.result,
        isReady: model.isReady,
        targetName: model.selectedTarget?.displayName,
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
          AgentSetupReplacementButton(
            presentation: model.failure?.presentation,
            action: onRepair
          )
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

struct AgentSetupReplacementButton: View {
  let presentation: AgentSetupFailurePresentation?
  let action: () -> Void

  private var label: String {
    presentation?.replacementActionLabel ?? "Replace Existing Setup…"
  }

  var body: some View {
    Button(action: action) {
      Text(verbatim: label)
    }
    .accessibilityLabel(Text(verbatim: label))
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
  let documentationURL: URL
  let agentInstructionsURL: URL

  var body: some View {
    VStack(spacing: 0) {
      AgentSetupScreenHeader(
        systemImage: "square.stack.3d.up",
        title: "Choose an Agent Harness",
        detail: "Inline configures only the selected installed harness."
      )

      List(installedTargets, selection: $selectedTargetID) { target in
        AgentSetupHarnessRow(
          target: target,
          documentationURL: documentationURL,
          agentInstructionsURL: agentInstructionsURL
        )
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
  let documentationURL: URL
  let agentInstructionsURL: URL

  var body: some View {
    HStack(spacing: 12) {
      AgentSetupHarnessIcon(
        targetID: target.id,
        fallbackSystemImage: target.family == .gateway ? "network" : "terminal"
      )
      VStack(alignment: .leading, spacing: 2) {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
          Text(target.displayName)
          if let maturityLabel {
            Text(maturityLabel)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
        Text(target.family == .gateway ? "Gateway integration" : "Local coding harness")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      AgentSetupHarnessResourcesMenu(
        target: target,
        documentationURL: documentationURL,
        agentInstructionsURL: agentInstructionsURL
      )
    }
    .padding(.vertical, 5)
  }

  private var maturityLabel: LocalizedStringResource? {
    switch target.id {
      case "codex":
        "(Alpha)"
      case "hermes", "opencode", "claude":
        "(Beta)"
      case "amp":
        "(Experimental)"
      default:
        nil
    }
  }
}

private struct AgentSetupHarnessResourcesMenu: View {
  let target: AgentHarnessTarget
  let documentationURL: URL
  let agentInstructionsURL: URL

  var body: some View {
    let links = resources

    Menu {
      Link(destination: links.guideURL) {
        Label("Open Setup Guide", systemImage: "book")
      }

      Button("Copy Setup Prompt", systemImage: "doc.on.doc", action: copySetupPrompt)

      if links.npmPackageURL != nil || links.sourceURL != nil {
        Divider()
      }

      if let npmPackageURL = links.npmPackageURL {
        Link(destination: npmPackageURL) {
          Label("View on npm", systemImage: "shippingbox")
        }
      }

      if let sourceURL = links.sourceURL {
        Link(destination: sourceURL) {
          Label("View Source Code", systemImage: "chevron.left.forwardslash.chevron.right")
        }
      }
    } label: {
      Image(systemName: "ellipsis.circle")
        .foregroundStyle(.secondary)
        .contentShape(.circle)
        .frame(width: 18, height: 18)
    }
    .menuStyle(.button)
    .buttonStyle(.plain)
    .fixedSize()
    .help("More about \(target.displayName)")
    .accessibilityLabel("More about \(target.displayName)")
  }

  private var resources: AgentSetupHarnessResources {
    switch target.id {
      case "openclaw":
        AgentSetupHarnessResources(
          guideURL: URL(string: "https://inline.chat/docs/openclaw")!,
          instructionsURL: URL(string: "https://inline.chat/docs/openclaw.md")!,
          npmPackageURL: URL(string: "https://www.npmjs.com/package/@inline-openclaw/inline")!,
          sourceURL: URL(string: "https://github.com/inline-chat/inline/tree/main/plugins/openclaw")!
        )
      case "hermes":
        AgentSetupHarnessResources(
          guideURL: URL(string: "https://inline.chat/docs/hermes")!,
          instructionsURL: URL(string: "https://inline.chat/docs/hermes.md")!,
          npmPackageURL: URL(string: "https://www.npmjs.com/package/@inline-chat/hermes-agent-adapter")!,
          sourceURL: URL(string: "https://github.com/inline-chat/inline/tree/main/plugins/hermes-agent")!
        )
      default:
        AgentSetupHarnessResources(
          guideURL: documentationURL,
          instructionsURL: agentInstructionsURL,
          npmPackageURL: nil,
          sourceURL: target.family == .bridge
            ? URL(string: "https://github.com/inline-chat/inline/tree/main/cli/src/bridge")!
            : nil
        )
    }
  }

  private func copySetupPrompt() {
    let prompt = "Set up my local \(target.displayName) as a bot in Inline:\n\(resources.instructionsURL.absoluteString)"
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(prompt, forType: .string)
    ToastCenter.shared.showSuccess("Copied setup prompt")
  }
}

private struct AgentSetupHarnessResources {
  let guideURL: URL
  let instructionsURL: URL
  let npmPackageURL: URL?
  let sourceURL: URL?
}

private struct AgentSetupHarnessIcon: View {
  let targetID: String
  let fallbackSystemImage: String
  var size: CGFloat = 40

  var body: some View {
    ZStack {
      Color(red: 0.969, green: 0.969, blue: 0.957)
      if let assetName {
        Image(assetName)
          .resizable()
          .scaledToFit()
      } else {
        Image(systemName: fallbackSystemImage)
          .imageScale(.medium)
          .foregroundStyle(.secondary)
      }
    }
    .frame(width: size, height: size)
    .clipShape(RoundedRectangle(cornerRadius: size / 4, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: size / 4, style: .continuous)
        .strokeBorder(.black.opacity(0.08), lineWidth: 0.5)
    }
    .accessibilityHidden(true)
  }

  private var assetName: String? {
    switch targetID {
    case "openclaw": "AgentHarnessOpenClaw"
    case "hermes": "AgentHarnessHermes"
    case "codex": "AgentHarnessCodex"
    case "opencode": "AgentHarnessOpenCode"
    case "claude": "AgentHarnessClaude"
    case "amp": "AgentHarnessAmp"
    default: nil
    }
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
  let targetID: String?
  let startedAt: Date?
  let items: [AgentSetupProgressItem]

  var body: some View {
    VStack(spacing: 0) {
      AgentSetupProgressHeader(
        title: title,
        targetID: targetID,
        startedAt: startedAt,
        items: items
      )
      .frame(maxWidth: 480)
      .padding(.horizontal, 32)
      .padding(.top, 24)
      .padding(.bottom, 16)

      ScrollView {
        AgentSetupProgressList(items: items)
          .frame(maxWidth: 480)
          .padding(.horizontal, 32)
          .padding(.bottom, 24)
          .frame(maxWidth: .infinity)
      }
      .scrollBounceBehavior(.basedOnSize)
    }
    .frame(maxWidth: .infinity)
  }
}

/// Live summary of the running step: what is happening now, how far along the
/// run is, and how long it has taken. Updates on every streamed CLI event.
private struct AgentSetupProgressHeader: View {
  let title: LocalizedStringResource
  let targetID: String?
  let startedAt: Date?
  let items: [AgentSetupProgressItem]

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack(spacing: 14) {
        AgentSetupHarnessIcon(
          targetID: targetID ?? "",
          fallbackSystemImage: "gearshape.2",
          size: 44
        )
        VStack(alignment: .leading, spacing: 3) {
          Text(title)
            .font(.title3.weight(.semibold))
          statusText
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
            .contentTransition(.opacity)
            .animation(.easeInOut(duration: 0.2), value: activeItem?.id)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }

      VStack(spacing: 6) {
        ProgressView(value: items.progressFraction)
          .progressViewStyle(.linear)
          .animation(.smooth(duration: 0.4), value: items.progressFraction)
        HStack {
          if let currentStep = items.currentStep {
            Text("Step \(currentStep) of \(items.count)")
          }
          if let startedAt {
            Text(startedAt, style: .timer)
              .monospacedDigit()
              .frame(maxWidth: .infinity, alignment: .trailing)
          }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
      }
    }
    .accessibilityElement(children: .combine)
  }

  private var activeItem: AgentSetupProgressItem? {
    items.first(where: \.isActive)
  }

  private var statusText: Text {
    if let activeItem {
      if let detail = activeItem.detail {
        return Text(verbatim: detail)
      }
      return Text(activeItem.id.activity)
    }
    return Text("Finishing up…")
  }
}

/// Vertical step timeline. Finished steps collapse to one line with their
/// outcome and duration; the running step expands with live detail.
private struct AgentSetupProgressList: View {
  let items: [AgentSetupProgressItem]

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
        AgentSetupProgressRow(
          item: item,
          isFirst: index == 0,
          isLast: index == items.count - 1
        )
      }
    }
    .animation(.smooth(duration: 0.3), value: items)
  }
}

private struct AgentSetupProgressRow: View {
  let item: AgentSetupProgressItem
  let isFirst: Bool
  let isLast: Bool

  private static let indicatorSize: CGFloat = 20

  private var verticalPadding: CGFloat { item.isActive ? 10 : 7 }

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      statusSymbol
        .frame(width: Self.indicatorSize, height: Self.indicatorSize)
        .padding(.top, verticalPadding)
        .frame(maxHeight: .infinity, alignment: .top)
        .background { connector }
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 3) {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Text(item.id.title)
            .font(item.isActive ? .body.weight(.semibold) : .body)
            .foregroundStyle(titleStyle)
            .frame(maxWidth: .infinity, alignment: .leading)
          trailing
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        if case .active = item.state {
          activeDetail
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .transition(.opacity)
        } else if case .failed = item.state {
          Text("Stopped here")
            .font(.callout)
            .foregroundStyle(.orange)
        }
      }
      .padding(.vertical, verticalPadding)
      // Center single-line rows on the 20pt indicator.
      .padding(.top, 1)
    }
    .padding(.horizontal, 10)
    .fixedSize(horizontal: false, vertical: true)
    .background {
      if item.isActive {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .fill(Color.accentColor.opacity(0.08))
      }
    }
    .accessibilityElement(children: .combine)
  }

  private var connector: some View {
    VStack(spacing: 0) {
      segment(color: isFirst ? .clear : topColor)
        .frame(height: verticalPadding)
      Color.clear
        .frame(height: Self.indicatorSize)
      segment(color: isLast ? .clear : bottomColor)
        .frame(maxHeight: .infinity)
    }
  }

  private func segment(color: Color) -> some View {
    Rectangle()
      .fill(color)
      .frame(width: 1.5)
  }

  private var topColor: Color {
    switch item.state {
    case .completed, .active, .failed: Color.green.opacity(0.5)
    case .pending: Color(nsColor: .separatorColor)
    }
  }

  private var bottomColor: Color {
    item.isCompleted ? Color.green.opacity(0.5) : Color(nsColor: .separatorColor)
  }

  @ViewBuilder
  private var statusSymbol: some View {
    switch item.state {
    case .pending:
      Circle()
        .strokeBorder(Color(nsColor: .tertiaryLabelColor), lineWidth: 1.5)
        .frame(width: 12, height: 12)
    case .active:
      ProgressView()
        .controlSize(.small)
    case .completed:
      Image(systemName: "checkmark.circle.fill")
        .font(.system(size: 17))
        .foregroundStyle(.white, .green)
        .transition(.scale.combined(with: .opacity))
    case .failed:
      Image(systemName: "exclamationmark.circle.fill")
        .font(.system(size: 17))
        .foregroundStyle(.white, .orange)
    }
  }

  @ViewBuilder
  private var trailing: some View {
    switch item.state {
    case let .active(startedAt):
      Text(startedAt, style: .timer)
        .monospacedDigit()
    case let .completed(outcome):
      HStack(spacing: 6) {
        if let outcome {
          Text(outcome.label)
        }
        if let duration = item.duration {
          Text(verbatim: AgentSetupDurationFormat.string(duration))
            .monospacedDigit()
            .foregroundStyle(.tertiary)
        }
      }
    case .pending, .failed:
      EmptyView()
    }
  }

  @ViewBuilder
  private var activeDetail: some View {
    if let detail = item.detail {
      Text(verbatim: detail)
    } else {
      Text(item.id.activity)
    }
  }

  private var titleStyle: HierarchicalShapeStyle {
    if case .pending = item.state { return .secondary }
    return .primary
  }
}

private enum AgentSetupDurationFormat {
  static func string(_ duration: TimeInterval) -> String {
    let seconds = max(1, Int(duration.rounded()))
    return Duration.seconds(seconds).formatted(
      .units(allowed: [.minutes, .seconds], width: .narrow)
    )
  }
}

private extension [AgentSetupProgressItem] {
  var currentStep: Int? {
    if let current = firstIndex(where: {
      switch $0.state {
      case .active, .failed: true
      case .pending, .completed: false
      }
    }) {
      return current + 1
    }
    let completed = count(where: \.isCompleted)
    return completed == 0 ? nil : Swift.min(completed + 1, count)
  }

  /// Completed steps plus partial credit for the running one, so the bar moves
  /// the moment a step starts instead of only when it ends.
  var progressFraction: Double {
    guard !isEmpty else { return 0 }
    let completed = Double(count(where: \.isCompleted))
    let active = contains(where: \.isActive) ? 0.4 : 0
    return Swift.min(1, (completed + active) / Double(count))
  }

  var totalDuration: TimeInterval? {
    let starts = compactMap(\.startedAt)
    let ends = compactMap(\.finishedAt)
    guard let start = starts.min(), let end = ends.max() else { return nil }
    return end.timeIntervalSince(start)
  }
}

private struct AgentSetupCompletionScreen: View {
  let result: AgentSetupResult?
  let isReady: Bool
  let targetName: String?
  let items: [AgentSetupProgressItem]
  @State private var showsSteps: Bool
  @State private var celebrated = false

  init(
    result: AgentSetupResult?,
    isReady: Bool,
    targetName: String?,
    items: [AgentSetupProgressItem]
  ) {
    self.result = result
    self.isReady = isReady
    self.targetName = targetName
    self.items = items
    // A clean run needs no step-by-step review; keep it one click away.
    _showsSteps = State(initialValue: !isReady)
  }

  var body: some View {
    ScrollView {
      VStack(spacing: 22) {
        hero

        VStack(alignment: .leading, spacing: 16) {
          if let result {
            summaryCard(result)
          }

          if let readiness = result?.readiness, !readiness.ready {
            AgentSetupRecoveryCard(readiness: readiness)
          } else if result?.service.ready == false {
            Label(
              "The configuration was saved, but the managed service still needs to start.",
              systemImage: "exclamationmark.triangle"
            )
            .foregroundStyle(.secondary)
          }

          if !items.isEmpty {
            DisclosureGroup(isExpanded: $showsSteps) {
              AgentSetupProgressList(items: items)
                .padding(.top, 6)
            } label: {
              stepsLabel
                .font(.callout)
                .foregroundStyle(.secondary)
            }
          }

          if isReady {
            Label(
              "Open the agent and send a first message to try it out.",
              systemImage: "bubble.left"
            )
            .font(.callout)
            .foregroundStyle(.secondary)
          }
        }
      }
      .frame(maxWidth: 460)
      .padding(.horizontal, 32)
      .padding(.vertical, 24)
      .frame(maxWidth: .infinity)
    }
    .scrollBounceBehavior(.basedOnSize)
    .onAppear { celebrated = true }
  }

  private var hero: some View {
    VStack(spacing: 10) {
      AgentSetupHarnessIcon(
        targetID: result?.target ?? "",
        fallbackSystemImage: "cpu",
        size: 60
      )
      .overlay(alignment: .bottomTrailing) {
        Image(systemName: isReady ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
          .font(.system(size: 22))
          .foregroundStyle(.white, isReady ? .green : .orange)
          .background(Circle().fill(Color(nsColor: .windowBackgroundColor)).padding(-2))
          .symbolEffect(.bounce, options: .nonRepeating, value: celebrated)
          .offset(x: 7, y: 7)
          .accessibilityHidden(true)
      }
      .padding(.bottom, 4)

      Text(title)
        .font(.title2.weight(.semibold))
      Text(summary)
        .font(.callout)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity)
  }

  private func summaryCard(_ result: AgentSetupResult) -> some View {
    GroupBox {
      VStack(spacing: 8) {
        LabeledContent("Bot") {
          Text(verbatim: "@\(result.bot.username)")
            .textSelection(.enabled)
            .lineLimit(1)
            .truncationMode(.middle)
        }
        Divider()
        LabeledContent("Harness") {
          Text(verbatim: targetName ?? result.target)
        }
        Divider()
        LabeledContent("Bridge Service") {
          HStack(spacing: 6) {
            Circle()
              .fill(result.service.ready ? Color.green : Color.orange)
              .frame(width: 7, height: 7)
            Text(result.service.ready ? "Running" : "Not running")
          }
        }
      }
      .padding(.horizontal, 4)
      .padding(.vertical, 2)
    }
  }

  private var stepsLabel: Text {
    let completed = items.count(where: \.isCompleted)
    if let total = items.totalDuration {
      return Text("\(completed) of \(items.count) steps completed in \(AgentSetupDurationFormat.string(total))")
    }
    return Text("\(completed) of \(items.count) steps completed")
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
      return "\(result.bot.name) is connected and running on this Mac."
    }
    return "\(result.bot.name) is configured, but needs attention before it can reply."
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

struct AgentSetupFailureScreen: View {
  let failure: AgentSetupFailure?
  let items: [AgentSetupProgressItem]
  @State private var showsDetails = false

  private var presentation: AgentSetupFailurePresentation? {
    failure?.presentation
  }

  var body: some View {
    ScrollView {
      VStack(spacing: 18) {
        AgentSetupScreenHeader(
          systemImage: "exclamationmark.triangle.fill",
          verbatimTitle: presentation?.title ?? "Setup Couldn’t Finish",
          verbatimDetail: presentation?.detail
            ?? "Inline kept completed steps and the diagnostic information needed to recover."
        )

        VStack(alignment: .leading, spacing: 16) {
          if let presentation {
            GroupBox {
              VStack(alignment: .leading, spacing: 12) {
                Text(verbatim: presentation.message)
                  .fixedSize(horizontal: false, vertical: true)
                  .frame(maxWidth: .infinity, alignment: .leading)
                if let actionLabel = presentation.actionLabel, let failure {
                  Button {
                    _ = NSWorkspace.shared.open(presentation.actionURL ?? failure.recoveryURL)
                  } label: {
                    Label {
                      Text(verbatim: actionLabel)
                    } icon: {
                      Image(systemName: "arrow.up.right")
                    }
                  }
                  .buttonStyle(.bordered)
                  .foregroundStyle(.primary)
                  .accessibilityLabel(Text(verbatim: actionLabel))
                }
              }
            } label: {
              Label {
                Text(verbatim: presentation.label)
              } icon: {
                Image(systemName: presentation.systemImage)
              }
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
      Text(failure.message)
        .font(.caption.monospaced())
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
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
      if let reportPath = failure.diagnosticReportPath {
        Text("Diagnostic report: \(reportPath)")
          .font(.caption.monospaced())
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
    if let reportPath = failure.diagnosticReportPath {
      lines.append("Diagnostic report: \(reportPath)")
    }
    return lines.joined(separator: "\n")
  }
}

private struct AgentSetupScreenHeader: View {
  let systemImage: String
  private let title: Text
  private let detail: Text

  init(
    systemImage: String,
    title: LocalizedStringResource,
    detail: LocalizedStringResource
  ) {
    self.systemImage = systemImage
    self.title = Text(title)
    self.detail = Text(detail)
  }

  init(
    systemImage: String,
    verbatimTitle: String,
    verbatimDetail: String
  ) {
    self.systemImage = systemImage
    self.title = Text(verbatim: verbatimTitle)
    self.detail = Text(verbatim: verbatimDetail)
  }

  var body: some View {
    VStack(spacing: 8) {
      Image(systemName: systemImage)
        .font(.title3.weight(.medium))
        .frame(width: 28, height: 28)
        .accessibilityHidden(true)
      title
        .font(.title3.weight(.semibold))
      detail
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

  /// Present-tense status shown while the step runs and the CLI has not sent
  /// its own message yet.
  var activity: LocalizedStringResource {
    switch self {
    case .cli: "Checking the Inline CLI…"
    case .authentication: "Connecting the CLI to your Inline account…"
    case .discovery: "Looking for agent harnesses on this Mac…"
    case .preflight: "Inspecting the existing setup…"
    case .bot: "Creating or reusing the Inline bot…"
    case .integration: "Configuring the Inline integration…"
    case .access: "Applying bot access controls…"
    case .service: "Starting the local bridge service…"
    case .verification: "Verifying the agent is ready…"
    case .configuration: "Configuring the agent…"
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
