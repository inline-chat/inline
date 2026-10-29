import InlineKit
import InlineMacUI
import InlineUI
import SwiftUI

// MARK: - Views

/// The row under the editor: the Agent and its folder at the leading edge;
/// context, model and reasoning at the trailing edge, as in the empty-page
/// Compose. A change applies to this Agent's work in this thread from the
/// next message on.
@available(macOS 26.0, *)
struct ComposeAgentChainBar: View {
  @ObservedObject var model: ComposeAgentChainModel

  var body: some View {
    if model.isAvailable {
      HStack(spacing: 2) {
        if let userInfo = model.botUserInfo {
          UserAvatar(userInfo: userInfo, size: 16)
            .frame(width: 24, height: 24)
            .inlineTooltip(
              verbatim: userInfo.user.displayName,
              description: "Gets this message and these settings. Start your message with another agent's mention to switch.",
              placement: .above
            )
            .accessibilityLabel("Agent: \(userInfo.user.displayName)")
        }

        if let title = model.projectTitle {
          if model.projectOptions.isEmpty {
            AllChatsComposePillLabel(title: title, systemImage: "folder")
              .fixedSize(horizontal: true, vertical: true)
              .inlineTooltip(
                verbatim: "Folder",
                description: model.projectDetail ?? "The folder this agent works in.",
                placement: .above
              )
          } else {
            AgentConfigurationMenu(
              title: title,
              automaticTitle: nil,
              options: model.projectOptions,
              selection: model.selectedProjectID,
              isDisabled: !model.canEdit,
              tooltipTitle: "Folder",
              tooltipDescription: "Choose the folder for this thread.",
              tooltipPlacement: .above,
              systemImage: "folder",
              select: model.selectProject
            )
          }
        }

        Spacer(minLength: 0)

        ComposeAgentUsageButton(model: model)

        if let title = model.modelTitle {
          AgentModelConfigurationMenu(
            title: title,
            automaticTitle: model.automaticModelTitle,
            options: model.modelOptions,
            selection: model.selectedModelID,
            isDisabled: !model.canEdit || model.modelOptions.isEmpty,
            tooltipPlacement: .above,
            select: model.selectModel
          )
        }

        if let title = model.reasoningTitle {
          AgentConfigurationMenu(
            title: title,
            automaticTitle: model.automaticReasoningTitle,
            options: model.reasoningOptions,
            selection: model.selectedReasoningID,
            isDisabled: !model.canEdit || model.reasoningOptions.isEmpty,
            tooltipTitle: "Reasoning",
            tooltipDescription: "Choose reasoning effort for this thread from the next message on.",
            tooltipPlacement: .above,
            select: model.selectReasoning
          )
        }
      }
      .padding(.leading, 6)
      .padding(.trailing, 8)
      .frame(height: 28)
    }
  }
}

/// A small ring for how full this thread's context is, with the numbers in
/// its tooltip. Clicking it shows the account's usage limits.
@available(macOS 26.0, *)
private struct ComposeAgentUsageButton: View {
  @ObservedObject var model: ComposeAgentChainModel
  @State private var isShowingUsage = false

  var body: some View {
    let fill = model.contextFill
    Button {
      model.prepareUsage()
      isShowingUsage.toggle()
    } label: {
      ZStack {
        Circle()
          .stroke(.quaternary, lineWidth: 2)
        if let fill {
          Circle()
            .trim(from: 0, to: fill.fraction)
            .stroke(
              fill.fraction >= 0.9 ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary),
              style: StrokeStyle(lineWidth: 2, lineCap: .round)
            )
            .rotationEffect(.degrees(-90))
        }
      }
      .frame(width: 12, height: 12)
      .frame(width: 24, height: 24)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .inlineTooltip(
      verbatim: fill.map { "Context window: \(Int(($0.fraction * 100).rounded()))% full" } ?? "Usage",
      description: fill.map { "\(ComposeAgentTokens.text($0.used)) / \(ComposeAgentTokens.text($0.window)) tokens used" }
        ?? "Show usage limits.",
      placement: .above
    )
    .accessibilityLabel("Usage")
    .accessibilityValue(fill.map { "Context \(Int(($0.fraction * 100).rounded())) percent full" } ?? "")
    .popover(isPresented: $isShowingUsage, arrowEdge: .bottom) {
      ComposeAgentUsagePopover(model: model)
    }
  }
}

/// The account's limits, one track each, then this thread's context.
@available(macOS 26.0, *)
private struct ComposeAgentUsagePopover: View {
  @ObservedObject var model: ComposeAgentChainModel

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Usage limits · \(model.agentName)")
        .font(.callout)
        .foregroundStyle(.secondary)
      content
    }
    .padding(14)
    .frame(width: 300, alignment: .leading)
  }

  @ViewBuilder
  private var content: some View {
    let windows = model.usageWindows
    if !windows.isEmpty || model.contextFill != nil {
      ForEach(windows) { window in
        track(
          title: window.title,
          detail: window.resetsAt.flatMap { $0 > .now ? Self.resetText($0) : nil },
          value: "\(window.usedPercent)%",
          fraction: Double(window.usedPercent) / 100
        )
      }
      if let fill = model.contextFill {
        if !windows.isEmpty { Divider() }
        track(
          title: String(localized: "Context window"),
          detail: "\(ComposeAgentTokens.text(fill.used)) / \(ComposeAgentTokens.text(fill.window))",
          value: "\(Int((fill.fraction * 100).rounded()))%",
          fraction: fill.fraction
        )
      }
    } else if let item = model.usageItem, let description = item.description {
      Text(description)
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    } else if let problem = model.settingsState?.problem {
      Label(problem.message, systemImage: "exclamationmark.triangle")
        .font(.callout)
        .foregroundStyle(.secondary)
    } else if model.settingsState?.phase == .loaded {
      Text("No usage reported yet. It shows after \(model.agentName)’s next turn.")
        .font(.callout)
        .foregroundStyle(.secondary)
    } else {
      HStack(spacing: 6) {
        ProgressView().controlSize(.small)
        Text("Asking \(model.agentName)…")
          .font(.callout)
          .foregroundStyle(.secondary)
      }
    }
  }

  private func track(title: String, detail: String?, value: String, fraction: Double) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack(spacing: 8) {
        Text(title)
        Spacer(minLength: 8)
        if let detail {
          Text(detail).foregroundStyle(.secondary)
        }
        Text(value)
          .monospacedDigit()
          .foregroundStyle(.secondary)
      }
      .font(.callout)
      ProgressView(value: min(1, max(0, fraction)))
        .progressViewStyle(.linear)
        .tint(fraction >= 0.9 ? .orange : .accentColor)
    }
  }

  /// "Resets at 2:30 PM" today, "Resets Tue 9:30 AM" this week, else a date.
  private static func resetText(_ date: Date) -> String {
    let calendar = Calendar.current
    if calendar.isDateInToday(date) {
      return String(localized: "Resets at \(date.formatted(date: .omitted, time: .shortened))")
    }
    if date.timeIntervalSinceNow < 6 * 24 * 3600 {
      let day = date.formatted(.dateTime.weekday(.abbreviated))
      return String(localized: "Resets \(day) \(date.formatted(date: .omitted, time: .shortened))")
    }
    return String(localized: "Resets \(date.formatted(.dateTime.month(.abbreviated).day()))")
  }
}


/// The circle beside the send button while an Agent's turn runs in this
/// chat: a quiet stop square, or a play glyph to resume paused work. Sending
/// stays available; a message while it works steers.
@available(macOS 26.0, *)
struct ComposeAgentRunButton: View {
  @ObservedObject var model: ComposeAgentChainModel
  @ObservedObject private var grants = AgentGrantStore.shared
  let size: CGFloat

  var body: some View {
    if let work = model.runWork {
      let paused = work.runState == .paused
      let name = model.runWorkName(work)
      let disabledReason = model.controlDisabledReason(work)
      Button(action: model.toggleRun) {
        Image(systemName: paused ? "play.fill" : "stop.fill")
          .font(.system(size: size * 0.3, weight: .bold))
          .foregroundStyle(.secondary)
          .frame(width: size, height: size)
        .contentShape(Circle())
      }
      .buttonStyle(.plain)
      .glassEffect(.regular.interactive(), in: .circle)
      .disabled(disabledReason != nil || model.isControlling || work.runState == .stopping)
      .inlineTooltip(
        verbatim: paused ? "Resume \(name)" : (work.runState == .stopping ? "Stopping \(name)…" : "Stop \(name)"),
        description: disabledReason ?? (paused ? "Continue the paused work." : "Sending a message still works; it steers the turn."),
        placement: .above
      )
      .accessibilityLabel(paused ? "Resume \(name)" : "Stop \(name)")
    }
  }
}
