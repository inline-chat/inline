import InlineKit
import InlineUI
import SwiftUI

/// What the agent row's host shows; the model changes with the chat.
@MainActor
final class ComposeAgentRowState: ObservableObject {
  @Published var model: ComposeAgentChainModel?
  @Published var isAvailable = false
}

struct ComposeAgentRowHost: View {
  @ObservedObject var state: ComposeAgentRowState
  let onAttach: () -> Void
  let onUsage: (CGRect) -> Void

  var body: some View {
    if let model = state.model {
      ComposeAgentRow(model: model, onAttach: onAttach, onUsage: onUsage)
    }
  }
}

/// The row under the text in the agent card: plus, the Agent, its folder
/// before the first turn, model and reasoning menus, then context and the
/// stop or resume circle. Send and voice stay UIKit, after the row.
struct ComposeAgentRow: View {
  @ObservedObject var model: ComposeAgentChainModel
  @ObservedObject private var grants = AgentGrantStore.shared
  let onAttach: () -> Void
  let onUsage: (CGRect) -> Void

  var body: some View {
    HStack(spacing: 0) {
      Button(action: onAttach) {
        Image(systemName: "plus")
          .font(.system(size: 19, weight: .regular))
          .foregroundStyle(.primary)
          .frame(width: 34, height: 32)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Attach")

      if let userInfo = model.botUserInfo {
        UserAvatar(userInfo: userInfo, size: 18)
          .padding(.leading, 4)
          .padding(.trailing, 2)
          .accessibilityLabel("Agent: \(userInfo.user.displayName)")
      }

      if model.isBeforeFirstTurn, let title = model.projectTitle, !model.projectOptions.isEmpty {
        ComposeAgentOptionMenu(
          title: title,
          systemImage: "folder",
          automaticTitle: nil,
          options: model.projectOptions,
          selection: model.selectedProjectID,
          isDisabled: !model.canEdit,
          accessibilityName: "Folder",
          select: model.selectProject
        )
      }

      if let title = model.modelTitle {
        ComposeAgentOptionMenu(
          title: title,
          systemImage: nil,
          automaticTitle: model.automaticModelTitle,
          options: model.modelOptions.map {
            AgentConfigurationOption(id: $0.id, label: $0.label, description: $0.description)
          },
          selection: model.selectedModelID,
          isDisabled: !model.canEdit || model.modelOptions.isEmpty,
          accessibilityName: "Model",
          select: model.selectModel
        )
      }

      if let title = model.reasoningTitle {
        ComposeAgentOptionMenu(
          title: title,
          systemImage: nil,
          automaticTitle: model.automaticReasoningTitle,
          options: model.reasoningOptions,
          selection: model.selectedReasoningID,
          isDisabled: !model.canEdit || model.reasoningOptions.isEmpty,
          accessibilityName: "Reasoning",
          select: model.selectReasoning
        )
      }

      Spacer(minLength: 0)

      if showsUsage {
        ComposeAgentContextRing(fill: model.contextFill, onTap: { frame in
          model.prepareUsage()
          onUsage(frame)
        })
      }

      if let work = model.runWork {
        ComposeAgentRunCircle(model: model, work: work)
      }
    }
    .lineLimit(1)
    // Labels arrive as settings load and the first turn starts; ease them in
    // rather than letting the row jump.
    .animation(.easeOut(duration: 0.18), value: rowShape)
  }

  /// Which optional pieces the row shows, so it animates only when they change.
  private var rowShape: [Bool] {
    [
      model.botUserInfo != nil,
      model.isBeforeFirstTurn && model.projectTitle != nil && !model.projectOptions.isEmpty,
      model.modelTitle != nil,
      model.reasoningTitle != nil,
      showsUsage,
      model.runWork != nil,
    ]
  }

  /// Usage is the agent owner's; it shows once the bridge reported some.
  private var showsUsage: Bool {
    model.contextFill != nil || !model.usageWindows.isEmpty || model.usageItem != nil
  }
}

/// A quiet label that opens a native pull-down menu: "Default — X" when the
/// harness has a default, then the options with a checkmark on the choice.
private struct ComposeAgentOptionMenu: View {
  let title: String
  let systemImage: String?
  let automaticTitle: String?
  let options: [AgentConfigurationOption]
  let selection: String?
  let isDisabled: Bool
  let accessibilityName: String
  let select: (String?) -> Void

  var body: some View {
    Menu {
      if let automaticTitle {
        Button {
          select(nil)
        } label: {
          optionLabel(automaticTitle, subtitle: nil, isSelected: selection == nil)
        }
        if !options.isEmpty { Divider() }
      }
      ForEach(options) { option in
        Button {
          select(option.id)
        } label: {
          optionLabel(option.label, subtitle: option.description, isSelected: selection == option.id)
        }
      }
    } label: {
      HStack(spacing: 4) {
        if let systemImage {
          Image(systemName: systemImage)
            .font(.system(size: 12, weight: .medium))
        }
        Text(title)
          .truncationMode(.tail)
        Image(systemName: "chevron.down")
          .font(.system(size: 9, weight: .semibold))
          .opacity(0.7)
      }
      .font(.system(size: 14, weight: .medium))
      .foregroundStyle(.secondary)
      .padding(.horizontal, 7)
      .frame(height: 32)
      .frame(maxWidth: 120)
      .contentShape(Rectangle())
    }
    .menuOrder(.fixed)
    .buttonStyle(.plain)
    .disabled(isDisabled)
    .accessibilityLabel(accessibilityName)
    .accessibilityValue(title)
  }

  @ViewBuilder
  private func optionLabel(_ title: String, subtitle: String?, isSelected: Bool) -> some View {
    if isSelected {
      Label {
        menuText(title, subtitle: subtitle)
      } icon: {
        Image(systemName: "checkmark")
      }
    } else {
      menuText(title, subtitle: subtitle)
    }
  }

  @ViewBuilder
  private func menuText(_ title: String, subtitle: String?) -> some View {
    Text(title)
    if let subtitle, !subtitle.isEmpty {
      Text(subtitle)
    }
  }
}

/// How full this thread's context is; a tap opens the usage popover.
private struct ComposeAgentContextRing: View {
  let fill: ComposeAgentChainModel.ContextFill?
  let onTap: (CGRect) -> Void
  @State private var frame: CGRect = .zero

  var body: some View {
    Button {
      onTap(frame)
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
      .frame(width: 15, height: 15)
      .frame(width: 32, height: 32)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .background {
      GeometryReader { proxy in
        Color.clear
          .onAppear { frame = proxy.frame(in: .global) }
          .onChange(of: proxy.frame(in: .global)) { _, next in frame = next }
      }
    }
    .accessibilityLabel("Usage")
    .accessibilityValue(fill.map { "Context \(Int(($0.fraction * 100).rounded())) percent full" } ?? "")
  }
}

/// Stop while the Agent works, play when its work is paused. Sending stays
/// available; a message while it works steers.
private struct ComposeAgentRunCircle: View {
  @ObservedObject var model: ComposeAgentChainModel
  let work: AgentWorkState

  var body: some View {
    let paused = work.runState == .paused
    let name = model.runWorkName(work)
    let disabled = model.controlDisabledReason(work) != nil || model.isControlling || work.runState == .stopping
    Button(action: model.toggleRun) {
      Image(systemName: paused ? "play.fill" : "stop.fill")
        .font(.system(size: 11, weight: .bold))
        .foregroundStyle(.primary)
        .frame(width: 30, height: 30)
        .background(Circle().fill(.quaternary))
        .frame(width: 34, height: 32)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(disabled)
    .opacity(disabled ? 0.45 : 1)
    .accessibilityLabel(paused ? "Resume \(name)" : "Stop \(name)")
  }
}

/// The usage popover: each account limit as a track, then this thread's
/// context.
struct ComposeAgentUsageView: View {
  @ObservedObject var model: ComposeAgentChainModel

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Usage limits · \(model.agentName)")
        .font(.subheadline)
        .foregroundStyle(.secondary)
      content
    }
    .padding(16)
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
    } else if let description = model.usageItem?.description {
      Text(description)
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    } else if let problem = model.settingsState?.problem {
      Label(problem.message, systemImage: "exclamationmark.triangle")
        .font(.subheadline)
        .foregroundStyle(.secondary)
    } else {
      HStack(spacing: 6) {
        ProgressView()
        Text("Asking \(model.agentName)…")
          .font(.subheadline)
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
      .font(.subheadline)
      ProgressView(value: min(1, max(0, fraction)))
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
