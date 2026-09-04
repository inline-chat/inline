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
    case .inviteFriend: "Invite a friend"
    case .createSpace: "Create a space"
    case .installTools: "Install our CLI, MCP, skill, etc"
    case .messageFounder: "Message @Mo (Inline Founder)"
    case .joinCommunity: "Join our community"
    }
  }

  var systemImage: String {
    switch self {
    case .setUpAgent: "teddybear"
    case .inviteFriend: "person.badge.plus"
    case .createSpace: "plus.circle"
    case .installTools: "terminal"
    case .messageFounder: "bubble.middle.bottom"
    case .joinCommunity: "person.2"
    }
  }
}

struct GettingStartedView: View {
  let dismiss: () -> Void
  let perform: @MainActor (GettingStartedAction) async -> Void

  @State private var isPerformingAction = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      GettingStartedLogo()
        .padding(.bottom, 12)

      GettingStartedHeader(dismiss: dismiss)
        .padding(.horizontal, 6)
        .padding(.bottom, 10)

      VStack(spacing: 2) {
        ForEach(GettingStartedAction.allCases) { action in
          GettingStartedActionRow(
            title: action.title,
            systemImage: action.systemImage,
            isDisabled: isPerformingAction
          ) {
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
    .frame(width: 300, alignment: .leading)
    .offset(y: -34)
  }
}

private struct GettingStartedLogo: View {
  var body: some View {
    Image("InlineLogoSymbol")
      .renderingMode(.template)
      .resizable()
      .scaledToFit()
      .frame(width: 26, height: 26)
      .foregroundStyle(.primary)
      .frame(width: 36, height: 36)
      .allowsHitTesting(false)
      .accessibilityHidden(true)
  }
}

private struct GettingStartedHeader: View {
  let dismiss: () -> Void

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var isHovered = false

  var body: some View {
    HStack(spacing: 10) {
      Text("Welcome to Inline")
        .font(.system(size: 15, weight: .medium))
        .foregroundStyle(.primary)

      Rectangle()
        .fill(Color.primary.opacity(0.12))
        .frame(width: 76, height: 1)

      Button("dismiss", action: dismiss)
        .font(.system(size: 13))
        .foregroundStyle(.secondary)
        .buttonStyle(.plain)
        .focusEffectDisabled(true)
        .opacity(isHovered ? 1 : 0)
        .allowsHitTesting(isHovered)
    }
    .frame(height: 24)
    .contentShape(Rectangle())
    .onHover { isHovered = $0 }
    .animation(reduceMotion ? nil : .easeInOut(duration: 0.1), value: isHovered)
  }
}

private struct GettingStartedActionRow: View {
  let title: String
  let systemImage: String
  let isDisabled: Bool
  let action: () -> Void

  @State private var isHovered = false

  var body: some View {
    Button(action: action) {
      HStack(spacing: 8) {
        Image(systemName: systemImage)
          .font(.system(size: 13, weight: .medium))
          .frame(width: 16, height: 16)
          .foregroundStyle(Color.secondary)

        Text(title)
          .font(.system(size: 13))
          .lineLimit(1)
          .foregroundStyle(Color.secondary)

      }
      .padding(.horizontal, 6)
      .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
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
      .scaleEffect(configuration.isPressed ? 0.95 : 1)
      .opacity(configuration.isPressed ? 0.8 : 1)
      .animation(.mediumFeedback, value: configuration.isPressed)
  }

  private func backgroundColor(isPressed: Bool) -> Color {
    if isPressed {
      Color.primary.opacity(0.15)
    } else if isHovered {
      Color.primary.opacity(0.03)
    } else {
      .clear
    }
  }
}
