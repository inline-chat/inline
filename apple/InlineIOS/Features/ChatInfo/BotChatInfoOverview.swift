import Auth
import InlineKit
import InlineUI
import SwiftUI

/// The owner's bot settings, opened from chat info. The settings page needs the
/// owner's bot record, which only the bot list returns.
@available(iOS 17.0, *)
struct OwnedBotSettingsDestination: View {
  let botUserID: Int64
  let model: IOSBotsSettingsModel

  @Environment(\.realtimeV2) private var realtimeV2
  @Environment(\.dismiss) private var dismiss
  @State private var didLoad = false

  var body: some View {
    Group {
      if model.bot(botUserID) != nil || didLoad {
        IOSManagedBotSettingsView(
          botID: botUserID,
          model: model,
          showsOpenChat: false,
          onDeleted: { dismiss() },
          copyToken: { BotsSettingsView.copyToken($0) }
        )
      } else {
        ProgressView()
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .task(id: botUserID) {
      await model.load(realtimeV2, failure: "Couldn’t load this bot. Go back and try again.")
      didLoad = true
    }
  }
}

// MARK: - Building blocks

/// "● Online" under a bot's name in its chat info header.
@available(iOS 17.0, *)
struct BotInfoStatusLine: View {
  let user: User
  @ObservedObject private var store = AgentWorkStateStore.shared

  var body: some View {
    if let status = BotStatusSummary.make(user: user, runtime: store.runtimeInfo(botUserID: user.id)) {
      HStack(spacing: 5) {
        Circle()
          .fill(status.tone.tint)
          .frame(width: 7, height: 7)
        Text(status.title)
      }
      .font(.callout)
      .foregroundStyle(.secondary)
      .accessibilityElement(children: .combine)
    }
  }
}

extension BotStatusSummary.Tone {
  var tint: Color {
    switch self {
    case .online: Color(uiColor: .systemGreen)
    case .offline: Color(uiColor: .systemGray)
    case .attention: Color(uiColor: .systemOrange)
    }
  }
}

/// A titled card, like a grouped list section.
@available(iOS 17.0, *)
struct BotInfoSection<Content: View>: View {
  let title: LocalizedStringKey
  let footer: String?
  let content: Content

  init(_ title: LocalizedStringKey, footer: String? = nil, @ViewBuilder content: () -> Content) {
    self.title = title
    self.footer = footer
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      Text(title)
        .font(.footnote.weight(.semibold))
        .foregroundStyle(.secondary)
        .textCase(.uppercase)
        .padding(.horizontal, 16)

      VStack(spacing: 0) {
        content
      }
      .background(Color(uiColor: .secondarySystemGroupedBackground))
      .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

      if let footer {
        Text(footer)
          .font(.footnote)
          .foregroundStyle(.secondary)
          .padding(.horizontal, 16)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// A Settings-style row: a tinted symbol tile, a title, an optional value on
/// the trailing edge and an optional line under the title.
@available(iOS 17.0, *)
struct BotInfoRow<Value: View, Detail: View>: View {
  let systemImage: String
  let tint: Color
  let title: LocalizedStringKey
  var showsChevron = false
  let value: Value
  let detail: Detail

  init(
    systemImage: String,
    tint: Color,
    title: LocalizedStringKey,
    showsChevron: Bool = false,
    @ViewBuilder value: () -> Value,
    @ViewBuilder detail: () -> Detail = { EmptyView() }
  ) {
    self.systemImage = systemImage
    self.tint = tint
    self.title = title
    self.showsChevron = showsChevron
    self.value = value()
    self.detail = detail()
  }

  var body: some View {
    HStack(spacing: 12) {
      BotInfoIconTile(systemImage: systemImage, tint: tint)

      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .foregroundStyle(.primary)
        detail
          .font(.footnote)
          .lineLimit(3)
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      value
        .lineLimit(1)

      if showsChevron {
        Image(systemName: "chevron.right")
          .font(.footnote.weight(.semibold))
          .foregroundStyle(.tertiary)
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
    .frame(minHeight: 48)
    .contentShape(Rectangle())
  }
}

@available(iOS 17.0, *)
struct BotInfoValueRow: View {
  let systemImage: String
  let tint: Color
  let title: LocalizedStringKey
  let value: String

  var body: some View {
    BotInfoRow(systemImage: systemImage, tint: tint, title: title) {
      Text(value)
        .foregroundStyle(.secondary)
        .truncationMode(.middle)
        .textSelection(.enabled)
    }
    .accessibilityElement(children: .combine)
  }
}

@available(iOS 16.0, *)
@available(iOS 17.0, *)
struct BotInfoIconTile: View {
  let systemImage: String
  let tint: Color

  var body: some View {
    Image(systemName: systemImage)
      .font(.system(size: 14, weight: .semibold))
      .foregroundStyle(.white)
      .frame(width: 29, height: 29)
      .background(tint.gradient, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
      .accessibilityHidden(true)
  }
}

/// Inset to line up with row titles, past the icon tile.
@available(iOS 17.0, *)
struct BotInfoDivider: View {
  var body: some View {
    Divider()
      .padding(.leading, 57)
  }
}

/// Overlapping avatars of people with access.
@available(iOS 17.0, *)
struct BotAccessAvatarStack: View {
  let userIDs: [Int64]
  let cachedUser: (Int64) -> UserInfo?

  var body: some View {
    HStack(spacing: -7) {
      ForEach(userIDs, id: \.self) { userID in
        Group {
          if let userInfo = cachedUser(userID) {
            UserAvatar(userInfo: userInfo, size: 24)
          } else {
            Circle().fill(Color(uiColor: .systemGray4))
          }
        }
        .frame(width: 24, height: 24)
        .overlay(Circle().stroke(Color(uiColor: .secondarySystemGroupedBackground), lineWidth: 2))
      }
    }
    .accessibilityHidden(true)
  }
}
