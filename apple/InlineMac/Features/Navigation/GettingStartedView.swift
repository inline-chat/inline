import Foundation
import SwiftUI

enum GettingStartedPreview {
  static var isForced: Bool {
#if DEBUG
    ProcessInfo.processInfo.arguments.contains("--show-getting-started")
#else
    false
#endif
  }
}

enum GettingStartedAction: String, CaseIterable, Identifiable {
  case setUpAgent
  case inviteFriend
  case createSpace
  case installTools
  case messageFounder
  case joinCommunity

  var id: String { rawValue }

  var title: String {
    switch self {
    case .setUpAgent: "Set up your agent"
    case .inviteFriend: "Invite your team"
    case .createSpace: "Create a space"
    case .installTools: "CLI, MCP, and skills"
    case .messageFounder: "Message Mo"
    case .joinCommunity: "Join the community"
    }
  }

  var systemImage: String {
    switch self {
    case .setUpAgent: "sparkles"
    case .inviteFriend: "person.badge.plus"
    case .createSpace: "square.grid.2x2"
    case .installTools: "terminal"
    case .messageFounder: "bubble.left"
    case .joinCommunity: "globe"
    }
  }

  /// Primary steps get full-strength text; the rest sit below a divider in secondary text.
  var isPrimary: Bool {
    switch self {
    case .setUpAgent, .inviteFriend, .createSpace: true
    case .installTools, .messageFounder, .joinCommunity: false
    }
  }

  var opensInBrowser: Bool {
    self == .installTools
  }

  static var primary: [GettingStartedAction] { allCases.filter(\.isPrimary) }
  static var secondary: [GettingStartedAction] { allCases.filter { !$0.isPrimary } }
}

private enum GettingStartedMetrics {
  static let width: CGFloat = 260
  static let rowInset: CGFloat = 7
  static let rowHeight: CGFloat = 28
}

struct GettingStartedView: View {
  let dismiss: () -> Void
  let perform: @MainActor (GettingStartedAction) async -> Void

  @State private var isPerformingAction = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      GettingStartedLogo()
        .padding(.leading, GettingStartedMetrics.rowInset)
        .padding(.bottom, 14)

      GettingStartedHeader()
        .padding(.horizontal, GettingStartedMetrics.rowInset)
        .padding(.bottom, 14)

      actionGroup(GettingStartedAction.primary)

      Divider()
        .padding(.horizontal, GettingStartedMetrics.rowInset)
        .padding(.vertical, 8)

      actionGroup(GettingStartedAction.secondary)

      GettingStartedHideButton(action: dismiss)
        .padding(.leading, GettingStartedMetrics.rowInset)
        .padding(.top, 12)
    }
    .frame(width: GettingStartedMetrics.width, alignment: .leading)
    .offset(y: -30)
  }

  private func actionGroup(_ actions: [GettingStartedAction]) -> some View {
    VStack(spacing: 1) {
      ForEach(actions) { action in
        GettingStartedActionRow(action: action, isDisabled: isPerformingAction) {
          guard !isPerformingAction else { return }
          isPerformingAction = true
          Task { @MainActor in
            await perform(action)
            isPerformingAction = false
          }
        }
      }
    }
  }
}

private struct GettingStartedLogo: View {
  var body: some View {
    Image("InlineLogoSymbol")
      .renderingMode(.template)
      .resizable()
      .scaledToFit()
      .frame(width: 22, height: 22)
      .foregroundStyle(.primary)
      .allowsHitTesting(false)
      .accessibilityHidden(true)
  }
}

private struct GettingStartedHeader: View {
  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      Text("Welcome to Inline")
        .font(.system(size: 15, weight: .semibold))
        .foregroundStyle(.primary)

      Text("Chat for your team and your agents.")
        .font(.system(size: 13))
        .foregroundStyle(.secondary)
    }
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(.isHeader)
  }
}

private struct GettingStartedHideButton: View {
  let action: () -> Void

  @State private var isHovered = false

  var body: some View {
    Button("Hide", action: action)
      .font(.system(size: 12))
      .foregroundStyle(isHovered ? HierarchicalShapeStyle.secondary : .tertiary)
      .buttonStyle(.plain)
      .focusEffectDisabled(true)
      .onHover { isHovered = $0 }
      .help("Hide getting started")
      .accessibilityLabel("Hide getting started")
  }
}

private struct GettingStartedActionRow: View {
  let action: GettingStartedAction
  let isDisabled: Bool
  let onTap: () -> Void

  @State private var isHovered = false

  var body: some View {
    Button(action: onTap) {
      HStack(spacing: 9) {
        Image(systemName: action.systemImage)
          .font(.system(size: 13))
          .frame(width: 18)

        Text(action.title)
          .font(.system(size: 13))
          .lineLimit(1)
          .frame(maxWidth: .infinity, alignment: .leading)

        if action.opensInBrowser {
          Image(systemName: "arrow.up.right")
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)
        }
      }
      .foregroundStyle(action.isPrimary ? HierarchicalShapeStyle.primary : .secondary)
      .padding(.horizontal, GettingStartedMetrics.rowInset)
      .frame(maxWidth: .infinity, minHeight: GettingStartedMetrics.rowHeight, alignment: .leading)
      .contentShape(Rectangle())
    }
    .buttonStyle(GettingStartedButtonStyle(isHovered: isHovered && !isDisabled))
    .focusEffectDisabled(true)
    .disabled(isDisabled)
    .onHover { isHovered = $0 }
  }
}

private struct GettingStartedButtonStyle: ButtonStyle {
  let isHovered: Bool

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .background(backgroundColor(isPressed: configuration.isPressed))
      .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
      .scaleEffect(configuration.isPressed ? 0.97 : 1)
      .animation(.mediumFeedback, value: configuration.isPressed)
  }

  private func backgroundColor(isPressed: Bool) -> Color {
    if isPressed {
      Color.primary.opacity(0.1)
    } else if isHovered {
      Color.primary.opacity(0.05)
    } else {
      .clear
    }
  }
}
